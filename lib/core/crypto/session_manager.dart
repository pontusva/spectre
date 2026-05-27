import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'identity_manager.dart';

/// Manages Signal Protocol sessions for outgoing and incoming messages.
///
/// Threat model notes:
///   * Content confidentiality and integrity come from the Double Ratchet
///     under each per-recipient session. After [initializeSession] runs,
///     [encryptMessage] / [decryptMessage] produce and consume Double
///     Ratchet ciphertext that gives us forward secrecy (compromise of the
///     current chain key cannot decrypt past messages) and post-compromise
///     security (a leaked chain key heals after the next DH ratchet step).
///
///   * What this layer does NOT hide: the sender's identifier on the wire.
///     If we just upload `(senderId, ciphertext)` to the relay, an attacker
///     who controls or subpoenas the relay learns the full social graph —
///     who talks to whom and when — even though they can't read the
///     content. For activists, journalists, and their sources this metadata
///     is often more dangerous than the message text itself: communication
///     with a known journalist or organizer is enough to identify a source
///     regardless of what was said.
///
///   * Sealed Sender is Signal's mitigation. The sender wraps the ratchet
///     ciphertext in a second envelope that is itself encrypted to the
///     recipient's identity key, and submits it to the relay over an
///     anonymous channel (no auth token, no sender claim). The relay sees
///     `(recipientId, opaque_blob)` and nothing more. The recipient
///     unwraps the outer envelope, learns who sent it (authenticated via a
///     sender certificate signed by the directory service), then decrypts
///     the inner ratchet message.
///
///   * IMPORTANT: This SessionManager only handles the inner Double-Ratchet
///     layer. Sealed Sender wrapping must be applied by the transport layer
///     before upload using [SealedSessionCipher] and a server-issued sender
///     certificate. Treat the ciphertext produced here as "needs to be put
///     in a sealed-sender envelope" — never upload it raw with a sender ID
///     attached, or the metadata-protection guarantee is silently lost.
class SessionManager {
  // Spectre is single-device per identity (no multi-device linking in v1),
  // so every peer is addressed with deviceId = 1. If we add linked devices
  // later, the address-resolution layer will need to know which deviceIds
  // a recipient has registered with the directory.
  static const int _kDefaultDeviceId = 1;

  // In-memory store: sessions, identity-trust state, and the ratchet keys
  // live only in process memory. They are NOT persisted across launches.
  // Rationale:
  //   * For a panic-wipe-friendly app, anything written to disk is a
  //     liability — secure storage is hardware-backed but still survives
  //     `adb pull`, forensic imaging, etc. Keeping ratchet state in RAM
  //     means a process kill is enough to drop it.
  //   * Trade-off: every cold start re-establishes sessions from prekey
  //     bundles, costing one round trip per peer. We accept that cost in
  //     exchange for the forensic-resistance property.
  //   * If a future version wants persistence (battery-friendly background
  //     delivery), swap this for an encrypted store that wipes alongside
  //     [IdentityManager.wipeIdentity].
  final InMemorySignalProtocolStore _store;

  SessionManager._(this._store);

  /// Builds a SessionManager bound to the device's long-term identity.
  /// Construct once at startup and share — concurrent use across isolates
  /// is NOT supported because [InMemorySignalProtocolStore] is not
  /// thread-safe.
  static Future<SessionManager> create(IdentityManager identityManager) async {
    final identity = await identityManager.loadOrCreate();
    final store = InMemorySignalProtocolStore(
      identity.identityKeyPair,
      identity.registrationId,
    );
    return SessionManager._(store);
  }

  SignalProtocolAddress _address(String recipientId) =>
      SignalProtocolAddress(recipientId, _kDefaultDeviceId);

  /// Establishes a Signal session with [recipientId] using the prekey
  /// bundle fetched from the relay's directory service.
  ///
  /// The bundle binds:
  ///   - the recipient's long-term identity key (for authentication)
  ///   - their current SignedPreKey + signature (medium-term DH leg)
  ///   - one of their one-time PreKeys, if any (forward-secrecy leg)
  ///
  /// libsignal verifies the SignedPreKey signature against the identity
  /// key. If the signature is bad, processPreKeyBundle throws and no
  /// session is created — that is the right failure mode, because a bad
  /// signature usually means either a MITM at the directory or a buggy
  /// peer, and we must not silently fall back to an unauthenticated
  /// session.
  Future<void> initializeSession(
    String recipientId,
    PreKeyBundle preKeyBundle,
  ) async {
    final address = _address(recipientId);
    final builder = SessionBuilder.fromSignalStore(_store, address);
    await builder.processPreKeyBundle(preKeyBundle);
  }

  /// Encrypts [plaintext] for [recipientId]. Caller must have already
  /// called [initializeSession] OR previously decrypted a PreKeySignalMessage
  /// from this peer — otherwise no session exists and this throws.
  ///
  /// The returned base64 string is a small JSON envelope carrying the
  /// libsignal ciphertext type tag plus the serialized message body. The
  /// type tag is what lets the recipient know whether to parse the body
  /// as a PreKeySignalMessage (first message of a session) or a plain
  /// SignalMessage (subsequent message in an established session).
  ///
  /// SECURITY: do not log the envelope, the plaintext, or the recipient
  /// ID. Logging is a frequent metadata-leak source on mobile.
  Future<String> encryptMessage(String recipientId, String plaintext) async {
    final address = _address(recipientId);
    final cipher = SessionCipher.fromStore(_store, address);

    final ciphertext = await cipher.encrypt(
      Uint8List.fromList(utf8.encode(plaintext)),
    );

    final envelope = <String, Object>{
      // 3 = PREKEY_TYPE (PreKeySignalMessage), 2 = WHISPER_TYPE (SignalMessage).
      // Carrying the tag explicitly avoids the recipient having to
      // sniff-parse the body, which is fragile and a known fuzzing surface.
      'type': ciphertext.getType(),
      'body': base64Encode(ciphertext.serialize()),
    };
    return base64Encode(utf8.encode(jsonEncode(envelope)));
  }

  /// Decrypts a message produced by [encryptMessage] from [recipientId].
  ///
  /// Handles both legs of the X3DH+Ratchet exchange:
  ///   * PreKeySignalMessage — the very first message from a new peer.
  ///     Decrypting it implicitly creates the session on our side and
  ///     consumes a one-time prekey from our store.
  ///   * SignalMessage — any subsequent message once the session is
  ///     established, advanced by the Double Ratchet.
  ///
  /// Throws [InvalidMessageException], [DuplicateMessageException],
  /// [UntrustedIdentityException], or [InvalidKeyIdException] depending
  /// on the failure mode. Callers should surface these to the user as
  /// "could not decrypt" without leaking which specific check failed —
  /// the distinction can be useful for an adversary probing the store.
  Future<String> decryptMessage(
    String recipientId,
    String ciphertextB64,
  ) async {
    final envelope = jsonDecode(utf8.decode(base64Decode(ciphertextB64)))
        as Map<String, dynamic>;
    final type = envelope['type'] as int;
    final body = base64Decode(envelope['body'] as String);

    final address = _address(recipientId);
    final cipher = SessionCipher.fromStore(_store, address);

    Uint8List plaintextBytes;
    if (type == CiphertextMessage.prekeyType) {
      // First message: parsing it constructs an implicit session using
      // the embedded prekey IDs to look up our own private halves. The
      // matching one-time prekey, if referenced, is automatically marked
      // for consumption by the underlying store.
      final preKeyMessage = PreKeySignalMessage(body);
      plaintextBytes = await cipher.decrypt(preKeyMessage);
    } else if (type == CiphertextMessage.whisperType) {
      // Subsequent message: requires an existing session. If no session
      // exists locally (e.g. user reinstalled, panic wiped, or we're out
      // of sync with the peer's ratchet), this throws and the UI should
      // prompt the peer to re-initiate by sending a new PreKeyMessage.
      final signalMessage = SignalMessage.fromSerialized(body);
      plaintextBytes = await cipher.decryptFromSignal(signalMessage);
    } else {
      // Anything else is either a corrupt envelope or a hostile peer
      // trying to confuse our parser. Fail closed.
      throw InvalidMessageException('Unknown ciphertext type: $type');
    }

    return utf8.decode(plaintextBytes);
  }

  /// Returns true if we have an established session with [recipientId].
  /// The transport layer should call this before sending and trigger
  /// [initializeSession] (after fetching a fresh prekey bundle) if false.
  Future<bool> hasSession(String recipientId) async {
    return _store.containsSession(_address(recipientId));
  }

  /// Drops the session for [recipientId]. The next outgoing message will
  /// require a new prekey-bundle fetch and [initializeSession]. Useful
  /// when the user manually triggers a re-key after a safety-number
  /// change, or as part of a per-conversation wipe.
  Future<void> deleteSession(String recipientId) async {
    await _store.deleteSession(_address(recipientId));
  }

  /// Drops every session. The store itself is in-memory, so a fresh
  /// [SessionManager.create] after this gives a completely clean slate.
  /// Call as part of the panic-wipe flow alongside
  /// [IdentityManager.wipeIdentity] and [PreKeyManager.wipeAll].
  Future<void> wipeAllSessions() async {
    await _store.deleteAllSessions('');
  }
}
