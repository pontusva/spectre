import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:spectre/core/crypto/sealed_sender.dart';

/// Round-trip and rejection tests for the in-house Sealed Sender
/// construction (sealed-sender-v1). These stand in for the relay's
/// certificate authority by self-signing certs with a locally generated
/// Ed25519 key — the SealedSender code path is identical regardless of who
/// holds the CA private half.
///
/// This is bespoke crypto; these tests are necessary but NOT sufficient for
/// production. See the crypto-review checklist in SPECTRE_DEVLOG.md.
void main() {
  const senderUid = 'sender-uid-AAAA';
  const recipientUid = 'recipient-uid-BBBB';
  const innerCt = 'aW5uZXItcmF0Y2hldC1jaXBoZXJ0ZXh0'; // opaque to sealed sender

  late ed.KeyPair ca;
  late Uint8List caPub;
  late SealedSender ss;

  // Recipient long-term Signal identity (the envelope is encrypted to it).
  late ECKeyPair recipientKp;
  late IdentityKeyPair recipientIdentity;

  // Sender identity key, raw 32B, as it will appear in the cert.
  late Uint8List senderIkRaw;

  Uint8List rawPub(ECPublicKey p) => Uint8List.fromList(p.serialize().sublist(1));

  ({Uint8List bytes, Uint8List sig}) makeCert({
    required String uid,
    required Uint8List ikRaw,
    required int expMs,
    ed.PrivateKey? signWith,
  }) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(<String, Object>{
      'uid': uid,
      'ik': base64.encode(ikRaw),
      'exp': expMs,
    })));
    final sig = ed.sign(signWith ?? ca.privateKey!, bytes);
    return (bytes: bytes, sig: sig);
  }

  setUp(() {
    ca = ed.generateKey();
    caPub = Uint8List.fromList(ca.publicKey!.bytes);
    ss = SealedSender(caPublicKey: caPub);

    recipientKp = Curve.generateKeyPair();
    recipientIdentity =
        IdentityKeyPair(IdentityKey(recipientKp.publicKey), recipientKp.privateKey);

    senderIkRaw = rawPub(Curve.generateKeyPair().publicKey);
  });

  test('seal -> open round-trips and authenticates the sender', () async {
    final now = 1_700_000_000_000;
    final cert =
        makeCert(uid: senderUid, ikRaw: senderIkRaw, expMs: now + 3600 * 1000);

    final blob = await ss.seal(
      recipientId: recipientUid,
      recipientIdentityKey: recipientKp.publicKey,
      certBytes: cert.bytes,
      certSignature: cert.sig,
      innerCiphertextB64: innerCt,
    );

    final opened = await ss.open(
      ownIdentityKeyPair: recipientIdentity,
      blob: blob,
      recipientId: recipientUid,
      nowMs: now,
    );

    expect(opened.senderId, senderUid);
    expect(opened.innerCiphertextB64, innerCt);
    expect(opened.senderIdentityKeyRaw, senderIkRaw);
  });

  test('tampered blob fails closed', () async {
    final now = 1_700_000_000_000;
    final cert =
        makeCert(uid: senderUid, ikRaw: senderIkRaw, expMs: now + 3600 * 1000);
    final blob = await ss.seal(
      recipientId: recipientUid,
      recipientIdentityKey: recipientKp.publicKey,
      certBytes: cert.bytes,
      certSignature: cert.sig,
      innerCiphertextB64: innerCt,
    );
    // Flip a byte in the AEAD ciphertext/tag region.
    blob[blob.length - 1] ^= 0xFF;

    expect(
      () => ss.open(
        ownIdentityKeyPair: recipientIdentity,
        blob: blob,
        recipientId: recipientUid,
        nowMs: now,
      ),
      throwsA(isA<SealedSenderException>()),
    );
  });

  test('wrong recipient (AAD mismatch) fails closed', () async {
    final now = 1_700_000_000_000;
    final cert =
        makeCert(uid: senderUid, ikRaw: senderIkRaw, expMs: now + 3600 * 1000);
    final blob = await ss.seal(
      recipientId: recipientUid,
      recipientIdentityKey: recipientKp.publicKey,
      certBytes: cert.bytes,
      certSignature: cert.sig,
      innerCiphertextB64: innerCt,
    );

    expect(
      () => ss.open(
        ownIdentityKeyPair: recipientIdentity,
        blob: blob,
        recipientId: 'someone-else',
        nowMs: now,
      ),
      throwsA(isA<SealedSenderException>()),
    );
  });

  test('expired certificate is rejected', () async {
    final now = 1_700_000_000_000;
    final cert = makeCert(
      uid: senderUid,
      ikRaw: senderIkRaw,
      expMs: now - 1, // already expired
    );
    final blob = await ss.seal(
      recipientId: recipientUid,
      recipientIdentityKey: recipientKp.publicKey,
      certBytes: cert.bytes,
      certSignature: cert.sig,
      innerCiphertextB64: innerCt,
    );

    expect(
      () => ss.open(
        ownIdentityKeyPair: recipientIdentity,
        blob: blob,
        recipientId: recipientUid,
        nowMs: now,
      ),
      throwsA(isA<SealedSenderException>()),
    );
  });

  test('malformed/short blob fails closed (not a raw exception)', () async {
    final now = 1_700_000_000_000;
    // Too short to even contain eph_pub + nonce + mac.
    expect(
      () => ss.open(
        ownIdentityKeyPair: recipientIdentity,
        blob: Uint8List.fromList(List<int>.filled(10, 0)),
        recipientId: recipientUid,
        nowMs: now,
      ),
      throwsA(isA<SealedSenderException>()),
    );
    // Right length but garbage ephemeral point + body: ECDH/decode/decrypt
    // must all fail closed as SealedSenderException, never a bare error.
    expect(
      () => ss.open(
        ownIdentityKeyPair: recipientIdentity,
        blob: Uint8List.fromList(List<int>.filled(80, 0)),
        recipientId: recipientUid,
        nowMs: now,
      ),
      throwsA(isA<SealedSenderException>()),
    );
  });

  test('certificate signed by a different CA is rejected', () async {
    final now = 1_700_000_000_000;
    final imposter = ed.generateKey();
    final cert = makeCert(
      uid: senderUid,
      ikRaw: senderIkRaw,
      expMs: now + 3600 * 1000,
      signWith: imposter.privateKey,
    );
    final blob = await ss.seal(
      recipientId: recipientUid,
      recipientIdentityKey: recipientKp.publicKey,
      certBytes: cert.bytes,
      certSignature: cert.sig,
      innerCiphertextB64: innerCt,
    );

    expect(
      () => ss.open(
        ownIdentityKeyPair: recipientIdentity,
        blob: blob,
        recipientId: recipientUid,
        nowMs: now,
      ),
      throwsA(isA<SealedSenderException>()),
    );
  });

  // Cross-language interop: this vector was produced by the Go relay's
  // crypto/ed25519 (seed = bytes 1..32; cert = IssueCert("sender-uid-AAAA",
  // base64(32 zero bytes), exp=1700000000000)). It proves the Dart
  // ed25519_edwards verifier accepts a Go-signed cert AND that such a cert
  // flows through seal()/open() end-to-end. Regenerate via the Go test if
  // the cert JSON shape ever changes (would be a wire-break).
  test('Go-signed certificate verifies and opens in Dart', () async {
    final goPub =
        base64.decode('ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ=');
    final goCert = base64.decode(
        'eyJ1aWQiOiJzZW5kZXItdWlkLUFBQUEiLCJpayI6IkFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE9IiwiZXhwIjoxNzAwMDAwMDAwMDAwfQ==');
    final goSig = base64.decode(
        '0Nt89CGht0MQuUC5OgufheIZCDPhU0aF3JWQ05DwCHN/N2Nu4X0AE5Ptg7PsGGbLtdsl1GpNJVpQ4WmgmZv4Ag==');

    // Direct proof: Dart verifies a Go crypto/ed25519 signature.
    expect(ed.verify(ed.PublicKey(goPub), goCert, goSig), isTrue);

    // End-to-end: the Go-signed cert flows through the sealed envelope.
    final goSs = SealedSender(caPublicKey: Uint8List.fromList(goPub));
    final blob = await goSs.seal(
      recipientId: recipientUid,
      recipientIdentityKey: recipientKp.publicKey,
      certBytes: Uint8List.fromList(goCert),
      certSignature: Uint8List.fromList(goSig),
      innerCiphertextB64: innerCt,
    );
    final opened = await goSs.open(
      ownIdentityKeyPair: recipientIdentity,
      blob: blob,
      recipientId: recipientUid,
      nowMs: 1699999999000, // before exp
    );
    expect(opened.senderId, 'sender-uid-AAAA');
    expect(opened.senderIdentityKeyRaw, Uint8List(32)); // 32 zero bytes
  });

  test('certificate with wrong-length ik is rejected', () async {
    final now = 1_700_000_000_000;
    final cert = makeCert(
        uid: senderUid, ikRaw: Uint8List(31), expMs: now + 3600 * 1000);
    final blob = await ss.seal(
      recipientId: recipientUid,
      recipientIdentityKey: recipientKp.publicKey,
      certBytes: cert.bytes,
      certSignature: cert.sig,
      innerCiphertextB64: innerCt,
    );
    expect(
      () => ss.open(
        ownIdentityKeyPair: recipientIdentity,
        blob: blob,
        recipientId: recipientUid,
        nowMs: now,
      ),
      throwsA(isA<SealedSenderException>()),
    );
  });

  test('expiry boundary nowMs == exp is rejected (>= check)', () async {
    final exp = 1_700_000_000_000;
    final cert = makeCert(uid: senderUid, ikRaw: senderIkRaw, expMs: exp);
    final blob = await ss.seal(
      recipientId: recipientUid,
      recipientIdentityKey: recipientKp.publicKey,
      certBytes: cert.bytes,
      certSignature: cert.sig,
      innerCiphertextB64: innerCt,
    );
    expect(
      () => ss.open(
        ownIdentityKeyPair: recipientIdentity,
        blob: blob,
        recipientId: recipientUid,
        nowMs: exp,
      ),
      throwsA(isA<SealedSenderException>()),
    );
  });

  test('SealedSender rejects a non-32-byte CA key', () {
    expect(
      () => SealedSender(caPublicKey: Uint8List(31)),
      throwsA(isA<SealedSenderException>()),
    );
  });

  group('Transcript and Key Commitment verification (H4)', () {
    final aead = Chacha20.poly1305Aead();
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

    Future<Uint8List> deriveKeyHelper(
      Uint8List dh,
      Uint8List ephPub,
      Uint8List recipPub,
      String recipId,
    ) async {
      final ikm = Uint8List(dh.length + ephPub.length + recipPub.length)
        ..setAll(0, dh)
        ..setAll(dh.length, ephPub)
        ..setAll(dh.length + ephPub.length, recipPub);
      final salt = Uint8List(32);
      final idBytes = utf8.encode(recipId);
      final info = BytesBuilder(copy: false)
        ..add(utf8.encode('spectre-sealed-sender-v1'))
        ..addByte(idBytes.length)
        ..add(idBytes);
      final derived = await hkdf.deriveKey(
        secretKey: SecretKey(ikm),
        nonce: salt,
        info: info.toBytes(),
      );
      return Uint8List.fromList(await derived.extractBytes());
    }

    test('mismatched recipient id commitment in plaintext is rejected', () async {
      final now = 1_700_000_000_000;
      final cert = makeCert(uid: senderUid, ikRaw: senderIkRaw, expMs: now + 3600 * 1000);

      final ephemeral = Curve.generateKeyPair();
      final ephPubRaw = rawPub(ephemeral.publicKey);
      final recipPubRaw = rawPub(recipientKp.publicKey);

      final dh = Curve.calculateAgreement(recipientKp.publicKey, ephemeral.privateKey);
      final keyBytes = await deriveKeyHelper(dh, ephPubRaw, recipPubRaw, recipientUid);

      // Create a payload where the recipient ID in AAD matches recipientUid,
      // but the inner commitment field 'recip_id' is tampered/mismatched.
      final badInner = utf8.encode(jsonEncode(<String, Object>{
        'cert': base64Encode(cert.bytes),
        'cert_sig': base64Encode(cert.sig),
        'ct': innerCt,
        'eph_pub': base64Encode(ephPubRaw),
        'recip_id': 'someone-else', // mismatched commitment
      }));

      final nonce = aead.newNonce();
      final box = await aead.encrypt(
        badInner,
        secretKey: SecretKey(keyBytes),
        nonce: nonce,
        aad: utf8.encode(recipientUid), // valid AAD to pass outer decryption
      );

      final blob = (BytesBuilder(copy: false)
        ..add(ephPubRaw)
        ..add(nonce)
        ..add(box.cipherText)
        ..add(box.mac.bytes)).toBytes();

      expect(
        () => ss.open(
          ownIdentityKeyPair: recipientIdentity,
          blob: blob,
          recipientId: recipientUid,
          nowMs: now,
        ),
        throwsA(
          isA<SealedSenderException>().having(
            (e) => e.reason,
            'reason',
            contains('recipient id commitment mismatch'),
          ),
        ),
      );
    });

    test('mismatched ephemeral key commitment in plaintext is rejected', () async {
      final now = 1_700_000_000_000;
      final cert = makeCert(uid: senderUid, ikRaw: senderIkRaw, expMs: now + 3600 * 1000);

      final ephemeral = Curve.generateKeyPair();
      final ephPubRaw = rawPub(ephemeral.publicKey);
      final recipPubRaw = rawPub(recipientKp.publicKey);

      final dh = Curve.calculateAgreement(recipientKp.publicKey, ephemeral.privateKey);
      final keyBytes = await deriveKeyHelper(dh, ephPubRaw, recipPubRaw, recipientUid);

      // Create a payload where the inner commitment field 'eph_pub' is mismatched.
      final badInner = utf8.encode(jsonEncode(<String, Object>{
        'cert': base64Encode(cert.bytes),
        'cert_sig': base64Encode(cert.sig),
        'ct': innerCt,
        'eph_pub': base64Encode(Uint8List(32)), // mismatched commitment
        'recip_id': recipientUid,
      }));

      final nonce = aead.newNonce();
      final box = await aead.encrypt(
        badInner,
        secretKey: SecretKey(keyBytes),
        nonce: nonce,
        aad: utf8.encode(recipientUid),
      );

      final blob = (BytesBuilder(copy: false)
        ..add(ephPubRaw)
        ..add(nonce)
        ..add(box.cipherText)
        ..add(box.mac.bytes)).toBytes();

      expect(
        () => ss.open(
          ownIdentityKeyPair: recipientIdentity,
          blob: blob,
          recipientId: recipientUid,
          nowMs: now,
        ),
        throwsA(
          isA<SealedSenderException>().having(
            (e) => e.reason,
            'reason',
            contains('ephemeral key commitment mismatch'),
          ),
        ),
      );
    });
  });
}
