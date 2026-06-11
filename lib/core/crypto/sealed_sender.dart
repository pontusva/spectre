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
///     Do NOT call the outer AEAD an "auth gate": the underlying X25519 does
///     not reject small-order/identity input points, so a degenerate dh = 0
///     would pass it (we now reject all-zero dh explicitly — finding R3-6 —
///     but the real authentication is still the inner cert + ratchet).
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

  /// Length-prefix width for the padded inner frame (big-endian uint32).
  static const int _kLenPrefix = 4;

  /// Padding bucket (bytes) for the inner plaintext BEFORE AEAD. The inner
  /// frame is `[uint32 realLen][inner json][zero pad]` rounded UP to a
  /// multiple of this, so the sealed blob length is quantised.
  ///
  /// R3-4: a first-contact PreKeySignalMessage (carrying the full X3DH
  /// bootstrap) is materially larger than an established-session
  /// WhisperMessage, and AEAD preserves length — so without padding the
  /// relay reads (recipient, time, size-class) and learns "a NEW conversation
  /// just formed with R", the relationship-formation event the threat model
  /// calls the worst thing to leak. Quantising to a coarse bucket makes a
  /// PreKey and a Whisper envelope indistinguishable by size up to the
  /// bucket, removing the type/first-contact oracle. 1024 comfortably covers
  /// a PreKey inner (cert + b64 ratchet ct) in a single bucket for short
  /// messages; longer texts simply occupy more buckets, exactly as they
  /// would unsealed, so this is a structural-type hide, not full traffic
  /// shaping (cover traffic / size padding for long messages remain out of
  /// scope — see review §8).
  static const int _kPadBucket = 1024;

  final Cipher _aead = Chacha20.poly1305Aead();
  final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// The all-zero X25519 output. `Curve.calculateAgreement` in the
  /// libsignal-java lineage this Dart port descends from does only
  /// null/type checks and hands off the raw RFC-7748 scalar multiply with
  /// NO abort-on-all-zero (contributory-behaviour) check. So an attacker who
  /// submits a small-order/identity ephemeral point forces a SHARED, PUBLIC
  /// `dh = 0` that anyone can compute — which would let them derive our HKDF
  /// key and pass the outer AEAD without ever doing a real DH. The outer
  /// layer is therefore NOT an authentication gate on its own (the real
  /// sender auth is the inner cert + ratchet); but we still reject the
  /// degenerate result so the outer layer keeps its cheap pre-cert
  /// confidentiality/DoS-filter value and the "can't pass without a real
  /// secret" property holds for legitimate traffic. See review finding R3-6.
  static final Uint8List _kZeroDh = Uint8List(32);

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

    // R3-4: pad the inner plaintext to a fixed bucket so a first-contact
    // PreKey envelope is not size-distinguishable from an established-session
    // Whisper envelope on the wire. The real length is carried in a 4-byte
    // prefix so the recipient strips the padding exactly.
    final padded = _padInner(Uint8List.fromList(inner));

    final nonce = _aead.newNonce(); // CSPRNG, length _kNonceLen
    final box = await _aead.encrypt(
      padded,
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
      final padded = await _aead.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(keyBytes),
        aad: utf8.encode(recipientId),
      );
      // R3-4: strip the length-prefixed padding applied in seal(). Runs over
      // AEAD-verified bytes, so a tampered length prefix can't reach here.
      innerBytes = _unpadInner(Uint8List.fromList(padded));
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
    /// The issuer the caller resolved [caPublicKey] for (the raw `iss`
    /// returned by [extractIssuer]). open() re-asserts cert.iss equals it so
    /// the verify path is self-contained: a cert from domain A can never be
    /// verified against domain B's pinned key without throwing, regardless
    /// of caller discipline.
    required String expectedIss,
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

    // FINDING-3 (part): bind the verified cert to the issuer whose CA key
    // was used to verify it. extractIssuer and open() parse the same bytes
    // today, but this assertion makes the verify path self-contained so a
    // future caller (or refactor) cannot pair cert and key from different
    // domains.
    if (cert.iss != expectedIss) {
      throw const SealedSenderException('cert issuer mismatch');
    }

    return OpenedSealed(
      senderId: cert.uid,
      senderDomain: cert.iss,
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
    // R3-6: reject the all-zero shared secret. A small-order/identity input
    // point yields dh = 0 (known to everyone), which the underlying
    // X25519 backend does not itself reject. Constant-time compare so we
    // don't add a timing distinguisher between zero and non-zero dh.
    if (_constantTimeEquals(dh, _kZeroDh)) {
      throw const SealedSenderException('degenerate (all-zero) key agreement');
    }
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

  /// Length-independent constant-time byte comparison. Used for the
  /// degenerate-dh check so a zero vs non-zero shared secret is not
  /// distinguishable by timing.
  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    var diff = a.length ^ b.length;
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// Frames [inner] as `[uint32 big-endian realLen][inner][zero pad]`, where
  /// the total is rounded UP to a multiple of [_kPadBucket]. See [_kPadBucket]
  /// for the rationale (R3-4 first-contact size oracle).
  static Uint8List _padInner(Uint8List inner) {
    final framedLen = _kLenPrefix + inner.length;
    // Round up to the next bucket; never produce a zero-length frame.
    final buckets = (framedLen + _kPadBucket - 1) ~/ _kPadBucket;
    final total = buckets * _kPadBucket;
    final out = Uint8List(total); // zero-filled padding by construction
    final len = inner.length;
    out[0] = (len >> 24) & 0xFF;
    out[1] = (len >> 16) & 0xFF;
    out[2] = (len >> 8) & 0xFF;
    out[3] = len & 0xFF;
    out.setRange(_kLenPrefix, _kLenPrefix + inner.length, inner);
    return out;
  }

  /// Inverse of [_padInner]. Reads the 4-byte length prefix and returns the
  /// exact inner bytes. Throws [SealedSenderException] on a malformed frame
  /// (too short, or a length that overruns the buffer) so a corrupt or
  /// adversarial padding can't read out of bounds. Only ever called on
  /// AEAD-verified plaintext.
  static Uint8List _unpadInner(Uint8List padded) {
    if (padded.length < _kLenPrefix) {
      throw const SealedSenderException('padded frame too short');
    }
    final len = (padded[0] << 24) |
        (padded[1] << 16) |
        (padded[2] << 8) |
        padded[3];
    if (len < 0 || _kLenPrefix + len > padded.length) {
      throw const SealedSenderException('padded frame length invalid');
    }
    return padded.sublist(_kLenPrefix, _kLenPrefix + len);
  }
}

/// Authenticated result of opening a sealed envelope.
class OpenedSealed {
  /// Relay handle of the sender, taken from the verified certificate.
  final String senderId;

  /// Issuer domain from the VERIFIED certificate — the only trustworthy
  /// statement of which relay's CA attested this sender. The domain half of
  /// the sender's federated identity MUST come from here, never from
  /// transport metadata like `federation_sender_relay` (unsigned and
  /// relay-controlled; see MessageService.deriveFullSenderId).
  final String senderDomain;

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
    required this.senderDomain,
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
