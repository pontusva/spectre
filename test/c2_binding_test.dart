import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:spectre/core/crypto/session_manager.dart';

/// Tests for the Sealed Sender C2 binding
/// ([SessionManager.assertFirstContactIdentity]): a first-contact PreKey
/// message's embedded identity key MUST match the identity key from the
/// verified sender certificate, or the message is dropped.
///
/// The PreKey message here is a REAL libsignal PreKeySignalMessage produced by
/// a genuine X3DH handshake, wrapped in the same {type, body} envelope
/// [SessionManager.encryptMessage] emits — so the test exercises the actual
/// parse-and-compare path, not a hand-rolled stand-in.
void main() {
  // Strip the 0x05 djb type tag → raw 32-byte coordinate, matching the cert's
  // `ik` form and SessionManager's internal comparison.
  Uint8List rawPub(ECPublicKey p) =>
      Uint8List.fromList(p.serialize().sublist(1));

  /// Builds Alice→Bob first-contact app envelope and returns it alongside
  /// Alice's raw identity key (the one embedded in the PreKey message).
  Future<({String envelope, Uint8List aliceIkRaw})> firstContactEnvelope() async {
    const bobUserId = 'bob-uid';
    const deviceId = 1;
    final bobAddress = SignalProtocolAddress(bobUserId, deviceId);

    // Bob (recipient) — identity, signed prekey, one-time prekey, bundle.
    final bobIdentity = KeyHelper.generateIdentityKeyPair();
    final bobRegId = KeyHelper.generateRegistrationId(false);
    final bobStore = InMemorySignalProtocolStore(bobIdentity, bobRegId);
    final bobSignedPre = KeyHelper.generateSignedPreKey(bobIdentity, 1);
    final bobOneTime = KeyHelper.generatePreKeys(1, 1).first;
    bobStore.storeSignedPreKey(bobSignedPre.id, bobSignedPre);
    bobStore.storePreKey(bobOneTime.id, bobOneTime);

    final bobBundle = PreKeyBundle(
      bobRegId,
      deviceId,
      bobOneTime.id,
      bobOneTime.getKeyPair().publicKey,
      bobSignedPre.id,
      bobSignedPre.getKeyPair().publicKey,
      bobSignedPre.signature,
      bobIdentity.getPublicKey(),
    );

    // Alice (sender) — establish session and encrypt the first message.
    final aliceIdentity = KeyHelper.generateIdentityKeyPair();
    final aliceStore =
        InMemorySignalProtocolStore(aliceIdentity, KeyHelper.generateRegistrationId(false));
    final builder = SessionBuilder.fromSignalStore(aliceStore, bobAddress);
    await builder.processPreKeyBundle(bobBundle);
    final cipher = SessionCipher.fromStore(aliceStore, bobAddress);
    final ct = await cipher.encrypt(Uint8List.fromList(utf8.encode('hi')));

    // First message must be a PreKeySignalMessage (carries the sender's IK).
    expect(ct.getType(), CiphertextMessage.PREKEY_TYPE);

    final envelope = base64Encode(utf8.encode(jsonEncode(<String, Object>{
      'type': ct.getType(),
      'body': base64Encode(ct.serialize()),
    })));

    return (
      envelope: envelope,
      aliceIkRaw: rawPub(aliceIdentity.getPublicKey().publicKey),
    );
  }

  test('matching identity passes', () async {
    final fc = await firstContactEnvelope();
    expect(
      () => SessionManager.assertFirstContactIdentity(fc.envelope, fc.aliceIkRaw),
      returnsNormally,
    );
  });

  test('mismatched identity throws IdentityBindingException', () async {
    final fc = await firstContactEnvelope();
    // A different key — what a hostile relay would staple a forged cert to.
    final wrongIk = rawPub(KeyHelper.generateIdentityKeyPair().getPublicKey().publicKey);
    expect(
      () => SessionManager.assertFirstContactIdentity(fc.envelope, wrongIk),
      throwsA(isA<IdentityBindingException>()),
    );
  });

  test('non-first-contact (WHISPER_TYPE) is a no-op regardless of key',
      () async {
    // Established-session messages carry no identity key; the binding does not
    // apply and must not throw even for an unrelated key.
    final whisperEnvelope = base64Encode(utf8.encode(jsonEncode(<String, Object>{
      'type': CiphertextMessage.WHISPER_TYPE,
      'body': base64Encode(utf8.encode('opaque-ratchet-body')),
    })));
    final anyKey = rawPub(KeyHelper.generateIdentityKeyPair().getPublicKey().publicKey);
    expect(
      () => SessionManager.assertFirstContactIdentity(whisperEnvelope, anyKey),
      returnsNormally,
    );
  });
}
