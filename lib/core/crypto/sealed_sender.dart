import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Sealed Sender — Spectre's in-house construction (sealed-sender-v1).
///
/// WHY THIS EXISTS: `libsignal_protocol_dart` 0.4.x does NOT ship
/// `SealedSessionCipher`/`SenderCertificate`. The metadata-protection
/// guarantee the rest of the app assumes (relay sees recipient + opaque
/// bytes, never the sender — even on first contact) therefore has to be
/// built on the primitives we do have:
///   * `Curve` (X25519 ECDH) from libsignal — interoperates directly with
///     the Curve25519 identity keys, no tag juggling for the agreement.
///   * `package:cryptography` HKDF-SHA256 + ChaCha20-Poly1305 for the
///     symmetric seal.
///   * `package:ed25519_edwards` to verify the relay-issued sender
///     certificate (same library/format the Go relay signs with).
///
/// THREAT MODEL FIT: the outer envelope is encrypted to the RECIPIENT's
/// long-term identity key and carries a relay-signed sender certificate
/// INSIDE the encrypted payload. The relay sees only
/// `(recipient_id, opaque_blob, timestamp)` — this is the metadata-hiding
/// win, and it holds against a passive relay and against other clients.
///
/// WHAT THE CERTIFICATE DOES *NOT* DO — read this before trusting senderId:
///   * The RELAY IS THE CERTIFICATE AUTHORITY and the relay is UNTRUSTED.
///     It holds the CA private key, so it can mint a cert binding ANY uid to
///     ANY identity key. A malicious relay can therefore forge sender
///     attribution and MITM a FIRST-CONTACT session (it controls both the
///     cert and the PreKey message, so the cert.ik == PreKeySignalMessage
///     identity-key binding it must pass is one it satisfies itself).
///   * The certificate is NOT sender authentication against the relay. It is
///     a metadata-hiding mechanism plus integrity against third parties and
///     a passive/honest relay. `senderId` returned here is a CLAIM.
///   * The ONLY trust anchor for "is this really Alice's key" is out-of-band
///     safety-number / fingerprint verification of the Signal identity key
///     (Spectre already has this — contact_screen "MARK AS VERIFIED").
///     That verification MUST remain mandatory and MUST NOT be presented as
///     replaced by the certificate. Treat senderId as unverified until the
///     identity key behind it has been fingerprint-verified.
///   * The outer ephemeral-ECDH layer is an anonymous sealed-box (libsodium
///     crypto_box_seal style): it gives confidentiality TO the recipient,
///     NOT authentication OF the sender. All sender authenticity comes from
///     the inner Signal session + out-of-band verification, never this layer.
///
/// SECURITY NOTES / FAIL-CLOSED:
///   * Every parse/verify failure throws [SealedSenderException]. Callers
///     MUST treat that as "drop the message" — never fall back to an
///     unsealed/unauthenticated path.
///   * Do not log blob bytes, keys, plaintext, or certificate fields. Log
///     `e.runtimeType` only, consistent with the rest of the app.
///   * This is bespoke cryptography. It MUST pass independent review before
///     production — see the crypto-review checklist in SPECTRE_DEVLOG.md.
class SealedSender {
  /// HKDF info string. Versioned so a future construction change is
  /// domain-separated and cannot be confused with v1 ciphertext.
  static const String _kInfo = 'spectre-sealed-sender-v1';

  /// libsignal djb curve type tag prefixed to raw 32-byte X25519 keys.
  static const int _kDjbTag = 0x05;

  static const int _kRawKeyLen = 32;
  static const int _kEphPubLen = 32;
  static const int _kNonceLen = 12; // ChaCha20-Poly1305 nonce
  static const int _kMacLen = 16; // Poly1305 tag

  final Cipher _aead = Chacha20.poly1305Aead();
  final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  // Removed _caPublicKey pinning to allow dynamic CA key resolution per issuer.

  SealedSender();

  /// Builds the outer sealed envelope.
  ///
  /// [recipientId] — relay handle of the recipient; bound as AEAD AAD.
  /// [recipientIdentityKey] — recipient's long-term Signal identity public
  ///   key (from their PreKeyBundle). The envelope is encrypted to it.
  /// [certBytes] / [certSignature] — the sender's OWN certificate, exactly
  ///   as issued by the relay (raw JSON bytes + Ed25519 signature over those
  ///   bytes). Embedded so the recipient can authenticate us.
  /// [innerCiphertextB64] — the output of `SessionManager.encryptMessage`
  ///   (the type+body Double-Ratchet envelope).
  ///
  /// Returns the opaque blob to place in `SealedEnvelope.ciphertext`:
  ///   `eph_pub(32) || nonce(12) || ciphertext || mac(16)`.
  Future<Uint8List> seal({
    required String recipientId,
    required ECPublicKey recipientIdentityKey,
    required Uint8List certBytes,
    required Uint8List certSignature,
    required String innerCiphertextB64,
  }) async {
    final ephemeral = Curve.generateKeyPair();
    final ephPubRaw = _rawPub(ephemeral.publicKey);
    final recipPubRaw = _rawPub(recipientIdentityKey);

    // ECDH can throw (e.g. a low-order / malformed recipient identity key
    // pulled from a hostile prekey bundle surfaces as ArgumentError from the
    // x25519 backend). Convert to the fail-closed contract type so callers
    // treat it as "could not seal", never as a fall-through.
    final Uint8List keyBytes;
    try {
      final dh = Curve.calculateAgreement(
        recipientIdentityKey,
        ephemeral.privateKey,
      );
      keyBytes = await _deriveKey(
        dh: dh,
        ephPubRaw: ephPubRaw,
        recipPubRaw: recipPubRaw,
        recipientId: recipientId,
      );
    } catch (_) {
      throw const SealedSenderException('seal key agreement failed');
    }

    final inner = utf8.encode(jsonEncode(<String, Object>{
      'cert': base64Encode(certBytes),
      'cert_sig': base64Encode(certSignature),
      'ct': innerCiphertextB64,
      'eph_pub': base64Encode(ephPubRaw),
      'recip_id': recipientId,
    }));

    final nonce = _aead.newNonce(); // CSPRNG, length _kNonceLen
    final box = await _aead.encrypt(
      inner,
      secretKey: SecretKey(keyBytes),
      nonce: nonce,
      // Bind the envelope to its routing target: a relay can't replay a
      // blob addressed to A as if it were addressed to B without the AEAD
      // failing on the recipient side.
      aad: utf8.encode(recipientId),
    );

    final builder = BytesBuilder(copy: false)
      ..add(ephPubRaw)
      ..add(nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return builder.toBytes();
  }

  /// Unwraps the outer envelope and parses the unverified certificate to extract
  /// the issuer claim (`iss`). This allows the caller to look up the correct
  /// CA key before calling [open].
  Future<String> extractIssuer({
    required IdentityKeyPair ownIdentityKeyPair,
    required Uint8List blob,
    required String recipientId,
  }) async {
    final inner = await _decryptInner(
      ownIdentityKeyPair: ownIdentityKeyPair,
      blob: blob,
      recipientId: recipientId,
    );
    final certB64 = inner['cert'];
    if (certB64 is! String) {
      throw const SealedSenderException('cert field missing');
    }
    final Uint8List certBytes;
    try {
      certBytes = base64Decode(certB64);
    } catch (_) {
      throw const SealedSenderException('cert base64 invalid');
    }
    final Map<String, dynamic> c;
    try {
      c = jsonDecode(utf8.decode(certBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const SealedSenderException('cert not json');
    }
    final iss = c['iss'];
    if (iss is! String) {
      throw const SealedSenderException('cert missing iss');
    }
    return iss;
  }

  Future<Map<String, dynamic>> _decryptInner({
    required IdentityKeyPair ownIdentityKeyPair,
    required Uint8List blob,
    required String recipientId,
  }) async {
    if (blob.length < _kEphPubLen + _kNonceLen + _kMacLen) {
      throw const SealedSenderException('blob too short');
    }
    var off = 0;
    final ephPubRaw = blob.sublist(off, off += _kEphPubLen);
    final nonce = blob.sublist(off, off += _kNonceLen);
    final cipherText = blob.sublist(off, blob.length - _kMacLen);
    final mac = blob.sublist(blob.length - _kMacLen);

    final List<int> innerBytes;
    try {
      final ephPub = Curve.decodePoint(_withTag(ephPubRaw), 0);
      final ownPrivate = ownIdentityKeyPair.getPrivateKey();
      final ownPubRaw = _rawPub(ownIdentityKeyPair.getPublicKey().publicKey);
      final dh = Curve.calculateAgreement(ephPub, ownPrivate);
      final keyBytes = await _deriveKey(
        dh: dh,
        ephPubRaw: ephPubRaw,
        recipPubRaw: ownPubRaw,
        recipientId: recipientId,
      );
      innerBytes = await _aead.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(keyBytes),
        aad: utf8.encode(recipientId),
      );
    } catch (_) {
      throw const SealedSenderException('outer open failed');
    }

    try {
      return jsonDecode(utf8.decode(innerBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const SealedSenderException('inner not json');
    }
  }

  /// Recipient-side unwrap. Decrypts the outer envelope with our identity
  /// private key, verifies the embedded sender certificate against the
  /// given CA key and its expiry, and returns the authenticated sender id
  /// plus the inner Double-Ratchet ciphertext.
  ///
  /// [ownIdentityKeyPair] — this device's Signal identity keypair.
  /// [blob] — the bytes from `SealedEnvelope.ciphertext`.
  /// [recipientId] — OUR relay handle; must equal the AAD the sender used.
  /// [nowMs] — current unix time in ms, for expiry checks (injected for
  ///   testability).
  ///
  /// Throws [SealedSenderException] on any malformed/forged/expired input.
  Future<OpenedSealed> open({
    required IdentityKeyPair ownIdentityKeyPair,
    required Uint8List blob,
    required String recipientId,
    required Uint8List caPublicKey,
    required int nowMs,
  }) async {
    final inner = await _decryptInner(
      ownIdentityKeyPair: ownIdentityKeyPair,
      blob: blob,
      recipientId: recipientId,
    );

    final certB64 = inner['cert'];
    final certSigB64 = inner['cert_sig'];
    final ct = inner['ct'];
    final ephPubCommitB64 = inner['eph_pub'];
    final recipIdCommit = inner['recip_id'];

    if (certB64 is! String ||
        certSigB64 is! String ||
        ct is! String ||
        ephPubCommitB64 is! String ||
        recipIdCommit is! String) {
      throw const SealedSenderException('inner fields missing');
    }

    if (recipIdCommit != recipientId) {
      throw const SealedSenderException('recipient id commitment mismatch');
    }
    // We need to extract ephPubRaw to verify the commitment. It's the first 32 bytes of the blob.
    final ephPubRaw = blob.sublist(0, _kEphPubLen);
    if (ephPubCommitB64 != base64Encode(ephPubRaw)) {
      throw const SealedSenderException('ephemeral key commitment mismatch');
    }

    final cert = _verifyCertificate(
      certB64: certB64,
      sigB64: certSigB64,
      caPublicKey: ed.PublicKey(_requireLen(caPublicKey, 32, 'CA pubkey')),
      nowMs: nowMs,
    );

    return OpenedSealed(
      senderId: cert.uid,
      senderIdentityKeyRaw: cert.identityKeyRaw,
      innerCiphertextB64: ct,
    );
  }

  /// Verifies a relay-issued sender certificate: Ed25519 signature over the
  /// exact issued bytes against the pinned CA key, then expiry. The fields
  /// are parsed from the SAME bytes that were signed (no re-canonicalization)
  /// so there is no signed-vs-parsed mismatch surface.
  SenderCertificate _verifyCertificate({
    required String certB64,
    required String sigB64,
    required ed.PublicKey caPublicKey,
    required int nowMs,
  }) {
    // base64 of the cert/sig comes from adversary-controlled inner JSON;
    // a malformed string must fail closed as SealedSenderException, not
    // escape as a raw FormatException (the class contract — same gate as
    // the AEAD/ECDH paths).
    final Uint8List certBytes;
    final Uint8List signature;
    try {
      certBytes = base64Decode(certB64);
      signature = base64Decode(sigB64);
    } catch (_) {
      throw const SealedSenderException('cert base64 invalid');
    }
    if (!ed.verify(caPublicKey, certBytes, signature)) {
      throw const SealedSenderException('cert signature invalid');
    }
    final Map<String, dynamic> c;
    try {
      c = jsonDecode(utf8.decode(certBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const SealedSenderException('cert not json');
    }
    final iss = c['iss'];
    final uid = c['uid'];
    final ikB64 = c['ik'];
    final expRaw = c['exp'];
    // `exp` arrives as a JSON number. On native Dart that decodes to int,
    // but on Dart-web ALL numbers are double — accept num and normalize so
    // a legitimately-issued cert is not spuriously rejected on web.
    if (iss is! String || uid is! String || ikB64 is! String || expRaw is! num) {
      throw const SealedSenderException('cert fields missing');
    }
    final exp = expRaw.toInt();
    if (nowMs >= exp) {
      throw const SealedSenderException('cert expired');
    }
    final Uint8List ik;
    try {
      ik = base64Decode(ikB64);
    } catch (_) {
      throw const SealedSenderException('cert ik base64 invalid');
    }
    if (ik.length != _kRawKeyLen) {
      throw const SealedSenderException('cert ik bad length');
    }
    return SenderCertificate(iss: iss, uid: uid, identityKeyRaw: ik, expiryMs: exp);
  }

  Future<Uint8List> _deriveKey({
    required Uint8List dh,
    required Uint8List ephPubRaw,
    required Uint8List recipPubRaw,
    required String recipientId,
  }) async {
    // Bind DH output and public keys directly into IKM (H3)
    final ikm = Uint8List(dh.length + ephPubRaw.length + recipPubRaw.length)
      ..setAll(0, dh)
      ..setAll(dh.length, ephPubRaw)
      ..setAll(dh.length + ephPubRaw.length, recipPubRaw);

    // Standard HKDF salt is fixed/non-secret (here 32 zero-bytes)
    final salt = Uint8List(32);

    // Fold length-prefixed recipient ID into HKDF info context (M4)
    final idBytes = utf8.encode(recipientId);
    final infoBuilder = BytesBuilder(copy: false)
      ..add(utf8.encode(_kInfo))
      ..addByte(idBytes.length)
      ..add(idBytes);
    final info = infoBuilder.toBytes();

    final derived = await _hkdf.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: salt,
      info: info,
    );
    return Uint8List.fromList(await derived.extractBytes());
  }

  static Uint8List _rawPub(ECPublicKey pub) {
    // serialize() is 33 bytes: 0x05 tag + 32-byte coordinate.
    final s = pub.serialize();
    return Uint8List.fromList(s.sublist(1));
  }

  static Uint8List _withTag(Uint8List raw32) {
    final out = Uint8List(raw32.length + 1);
    out[0] = _kDjbTag;
    out.setAll(1, raw32);
    return out;
  }

  static Uint8List _requireLen(Uint8List b, int n, String what) {
    if (b.length != n) {
      throw SealedSenderException('$what wrong length');
    }
    return b;
  }
}

/// Authenticated result of opening a sealed envelope.
class OpenedSealed {
  /// Relay handle of the sender, taken from the verified certificate.
  final String senderId;

  /// Sender's Signal identity public key (raw 32 bytes) as attested by the
  /// certificate. The caller MUST check this equals the identity key inside
  /// a PreKeySignalMessage before establishing a session, binding the cert
  /// to the actual ratchet message.
  final Uint8List senderIdentityKeyRaw;

  /// The inner Double-Ratchet ciphertext (output of
  /// `SessionManager.encryptMessage`) to hand to `decryptMessage`.
  final String innerCiphertextB64;

  const OpenedSealed({
    required this.senderId,
    required this.senderIdentityKeyRaw,
    required this.innerCiphertextB64,
  });
}

/// Parsed, signature-verified sender certificate.
class SenderCertificate {
  final String iss;
  final String uid;
  final Uint8List identityKeyRaw;
  final int expiryMs;

  const SenderCertificate({
    required this.iss,
    required this.uid,
    required this.identityKeyRaw,
    required this.expiryMs,
  });
}

/// Thrown on ANY malformed, forged, expired, or undecryptable input.
/// Callers must fail closed (drop the message) — never fall back to an
/// unsealed path.
class SealedSenderException implements Exception {
  final String reason;
  const SealedSenderException(this.reason);
  @override
  String toString() => 'SealedSenderException: $reason';
}
