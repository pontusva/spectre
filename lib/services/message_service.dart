import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';
import 'package:uuid/uuid.dart';

import '../core/crypto/identity_manager.dart';
import '../core/crypto/prekey_manager.dart';
import '../core/crypto/relay_auth_manager.dart';
import '../core/crypto/session_manager.dart';
import '../core/models/conversation.dart';
import '../core/models/message.dart';
import '../core/storage/secure_database.dart';
import 'network/prekey_service.dart';
import 'network/relay_service.dart';

/// DEV-ONLY sender attribution shortcut for local two-device testing.
///
/// When true, the sender's user id is wrapped (in CLEARTEXT) alongside the
/// ratchet ciphertext on the wire so the recipient can attribute and route a
/// message WITHOUT Sealed Sender being wired up yet. This intentionally LEAKS
/// the sender id to anyone who can parse the ciphertext blob — including the
/// relay — so it MUST NEVER be enabled for the production/activist build. The
/// secure replacement is Sealed Sender (see SEALED_SENDER_REVIEW.md); when
/// that lands, this flag and its [_devWrap]/[_devUnwrap] helpers go away.
///
/// Off by default — a production build has no sender attribution path until
/// Sealed Sender is wired. Enable for local testing with:
///   flutter run --dart-define=SPECTRE_DEV_ATTRIBUTION=true
const bool kDevSenderAttribution =
    bool.fromEnvironment('SPECTRE_DEV_ATTRIBUTION', defaultValue: false);

/// Coarse outcome of a [MessageService.sendMessage] call.
enum MessageStatus {
  /// Encrypted, persisted, and acknowledged by the relay.
  sent,

  /// Encrypted and persisted locally, but the relay is offline or
  /// rejected delivery. Will retry on next reconnect.
  pending,

  /// Encryption failed or the database refused the write. Nothing is
  /// queued — the caller should surface an error to the user.
  failed,
}

/// A decrypted message handed to the UI for rendering.
///
/// This type is INTENTIONALLY not a database model. There is no
/// `toMap`, no `fromMap`, no `copyWith`, and no companion table. It
/// exists for the lifetime of a single UI event:
///
///   relay frame -> decrypt -> emit DecryptedMessage -> widget rebuild
///
/// After the widget consumes it, the value should fall out of scope
/// and be garbage-collected. Holding it in a long-lived list, cache,
/// or provider is a security bug: plaintext that survives the next
/// app foreground was never supposed to exist on this device at all.
class DecryptedMessage {
  final String id;
  final String senderId;
  final String conversationId;
  final String plaintext;
  final DateTime timestamp;

  const DecryptedMessage({
    required this.id,
    required this.senderId,
    required this.conversationId,
    required this.plaintext,
    required this.timestamp,
  });
}

class _PendingSend {
  final String messageId;
  final String recipientId;
  final String ciphertextB64;
  final DateTime timestamp;
  int attempts;

  _PendingSend({
    required this.messageId,
    required this.recipientId,
    required this.ciphertextB64,
    required this.timestamp,
    this.attempts = 0,
  });
}

class MessageService {
  final IdentityManager _identity;
  final PreKeyManager _prekeys;
  final SessionManager _sessions;
  final SecureDatabase _db;
  final RelayService _relay;
  final RelayAuthManager _relayAuth;
  // Used by the inbound first-message flow to fetch a peer's PreKeyBundle
  // and bootstrap a session on the fly when decryption fails for lack of
  // one. See receiveMessage().
  final PrekeyService _prekeyService;

  final Uuid _uuid;
  final StreamController<DecryptedMessage> _decryptedController =
      StreamController<DecryptedMessage>.broadcast();

  /// In-memory only. By design this queue is lost on process death and
  /// on [panicWipe]. Persisting pending sends to disk would defeat the
  /// "nothing plaintext-adjacent survives a wipe" property.
  final Map<String, _PendingSend> _pending = <String, _PendingSend>{};

  /// In-memory dedup ledger for inbound message IDs. [insertMessage]
  /// uses upsert semantics, so a duplicate inbound envelope would
  /// silently overwrite the existing row with identical content — that
  /// is fine for the row, but we must NOT re-emit a DecryptedMessage
  /// for the same ID. This set is the gate. It dies with the process,
  /// which is consistent with the wipe-on-restart property of session
  /// state generally.
  final Set<String> _seenMessageIds = <String>{};

  StreamSubscription<Map<String, dynamic>>? _incomingSub;
  StreamSubscription<RelayConnectionState>? _stateSub;
  bool _wiped = false;

  MessageService({
    required IdentityManager identityManager,
    required PreKeyManager preKeyManager,
    required SessionManager sessionManager,
    required SecureDatabase database,
    required RelayService relayService,
    required RelayAuthManager relayAuthManager,
    required PrekeyService prekeyService,
    Uuid? uuid,
  })  : _identity = identityManager,
        _prekeys = preKeyManager,
        _sessions = sessionManager,
        _db = database,
        _relay = relayService,
        _relayAuth = relayAuthManager,
        _prekeyService = prekeyService,
        _uuid = uuid ?? const Uuid() {
    _incomingSub = _relay.incoming.listen(_onRelayFrame);
    _stateSub = _relay.connectionState.listen((state) {
      if (state == RelayConnectionState.connected) {
        unawaited(_drainPending());
      }
    });
  }

  Stream<DecryptedMessage> get decryptedMessages =>
      _decryptedController.stream;

  Future<MessageStatus> sendMessage(
    String recipientId,
    String plaintext,
  ) async {
    if (_wiped) {
      throw StateError('MessageService has been wiped');
    }

    final String ciphertextB64;
    try {
      ciphertextB64 = await _sessions.encryptMessage(recipientId, plaintext);
    } catch (e) {
      _log('encrypt failed for ${_redactId(recipientId)} :: ${e.runtimeType}');
      return MessageStatus.failed;
    }

    final messageId = _uuid.v4();
    final identity = await _identity.loadOrCreate();
    final conversationId = await _ensureConversation(recipientId);
    final now = DateTime.now().toUtc();

    // What goes on the wire. With DEV attribution this wraps our user id in
    // cleartext alongside the ciphertext; otherwise it is the raw ratchet
    // ciphertext (and the recipient currently has no way to attribute it
    // until Sealed Sender is wired). The local DB always stores the raw
    // ciphertext, never the wrapper.
    final wireCtB64 = kDevSenderAttribution
        ? _devWrap(identity.userId, ciphertextB64)
        : ciphertextB64;

    final ciphertextBytes = Uint8List.fromList(utf8.encode(ciphertextB64));
    try {
      await _db.insertMessage(Message(
        id: messageId,
        conversationId: conversationId,
        senderId: identity.userId,
        ciphertext: ciphertextBytes,
        timestamp: now,
        isRead: true,
        isMine: true,
      ));
    } catch (e) {
      _log('persist failed :: ${e.runtimeType}');
      return MessageStatus.failed;
    }

    if (_relay.currentState != RelayConnectionState.connected) {
      _pending[messageId] = _PendingSend(
        messageId: messageId,
        recipientId: recipientId,
        ciphertextB64: wireCtB64,
        timestamp: now,
      );
      _log('queued pending send id=${_redactId(messageId)}');
      return MessageStatus.pending;
    }

    try {
      await _relay.sendMessage(
        recipientId: recipientId,
        ciphertextB64: wireCtB64,
        sealed: true,
      );
      return MessageStatus.sent;
    } catch (e) {
      _pending[messageId] = _PendingSend(
        messageId: messageId,
        recipientId: recipientId,
        ciphertextB64: wireCtB64,
        timestamp: now,
      );
      _log('send failed -> pending :: ${e.runtimeType}');
      return MessageStatus.pending;
    }
  }

  Future<void> receiveMessage(Map<String, dynamic> envelope) async {
    if (_wiped) return;

    final rawCiphertext = envelope['ciphertext'];
    // The relay delivers the Go-side field `timestamp_ms`; tolerate a legacy
    // `timestamp` too. (The old code read `timestamp`, which the relay never
    // sends — so every inbound message was dropped as malformed.)
    final timestampMs = envelope['timestamp_ms'] ?? envelope['timestamp'];

    if (rawCiphertext is! String || timestampMs is! int) {
      _log('dropped envelope: malformed');
      return;
    }

    // Resolve the sender. With DEV attribution we unwrap a cleartext
    // {from, ct} wrapper carried inside the ciphertext field (local
    // two-device testing only — see [kDevSenderAttribution]). Otherwise we
    // fall back to an envelope `sender_id`; note Sealed Sender (the real
    // authenticated source) is not wired yet, so without the dev flag a
    // sealed envelope has no sender and is dropped.
    final String senderId;
    final String ciphertextB64;
    if (kDevSenderAttribution) {
      final unwrapped = _devUnwrap(rawCiphertext);
      if (unwrapped == null) {
        _log('dropped envelope: dev attribution wrapper parse failed');
        return;
      }
      senderId = unwrapped.$1;
      ciphertextB64 = unwrapped.$2;
    } else {
      final senderIdRaw = envelope['sender_id'];
      if (senderIdRaw is! String) {
        _log('dropped envelope: no resolved sender (sealed sender not wired)');
        return;
      }
      senderId = senderIdRaw;
      ciphertextB64 = rawCiphertext;
    }

    final ciphertextBytes = Uint8List.fromList(utf8.encode(ciphertextB64));
    final messageId = _contentHashId(ciphertextBytes);

    // In-memory dedup gate. See [_seenMessageIds] for rationale.
    if (_seenMessageIds.contains(messageId)) {
      _log(
        'duplicate inbound from ${_redactId(senderId)} '
        'id=${_redactId(messageId)} ignored',
      );
      return;
    }

    final conversationId = await _ensureConversation(senderId);

    final timestamp =
        DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true);

    String? plaintext;
    try {
      plaintext = await _sessions.decryptMessage(senderId, ciphertextB64);
    } catch (e) {
      // Signal "first message" flow: the very first ciphertext a peer
      // sends us is a PreKeySignalMessage, and decryption fails here
      // because we have no session for them yet. The receiver bootstraps
      // its half of the session from the peer's published PreKeyBundle
      // (the same bundle whose one-time prekey the sender already
      // consumed when they built the PreKeySignalMessage), then retries.
      _log(
        'decrypt failed from ${_redactId(senderId)} :: ${e.runtimeType} '
        '-- attempting first-message session init',
      );
      final bundle = await _prekeyService.fetchBundle(senderId);
      if (bundle != null) {
        await _sessions.initializeSession(senderId, bundle);
        try {
          plaintext = await _sessions.decryptMessage(senderId, ciphertextB64);
        } catch (e2) {
          _log(
            'decrypt retry failed from ${_redactId(senderId)} '
            ':: ${e2.runtimeType}',
          );
        }
      } else {
        _log('no prekey bundle for ${_redactId(senderId)}');
      }
    }

    try {
      await _db.insertMessage(Message(
        id: messageId,
        conversationId: conversationId,
        senderId: senderId,
        ciphertext: ciphertextBytes,
        timestamp: timestamp,
      ));
    } catch (e) {
      _log('inbound persist failed :: ${e.runtimeType}');
      return;
    }

    _seenMessageIds.add(messageId);

    // Still undecryptable after a session-init retry: the ciphertext is
    // stored above for later reprocessing, but we emit nothing — there is
    // no plaintext to hand the UI.
    if (plaintext == null) return;

    if (!_decryptedController.isClosed) {
      _decryptedController.add(DecryptedMessage(
        id: messageId,
        senderId: senderId,
        conversationId: conversationId,
        plaintext: plaintext,
        timestamp: timestamp,
      ));
    }
  }

  Future<void> _onRelayFrame(Map<String, dynamic> envelope) async {
    // The relay delivers SealedEnvelope/OpenEnvelope frames by SHAPE, with no
    // `type` field — so gating on `type == 'message'` (as the old code did)
    // dropped every delivered message. Control frames (auth/cert) are handled
    // inside RelayService and never reach this stream, so any frame here that
    // carries a ciphertext is a delivery.
    if (envelope['ciphertext'] is! String) return;
    await receiveMessage(envelope);
  }

  /// DEV-ONLY ([kDevSenderAttribution]): pack the sender id in cleartext
  /// alongside the ratchet ciphertext. base64(json) so it survives the
  /// relay's opaque `ciphertext` field untouched. NOT a security boundary —
  /// the relay can read `from`. Removed when Sealed Sender lands.
  String _devWrap(String senderId, String ciphertextB64) {
    return base64Encode(utf8.encode(
      jsonEncode(<String, String>{'from': senderId, 'ct': ciphertextB64}),
    ));
  }

  /// Inverse of [_devWrap]. Returns (senderId, ciphertextB64) or null if the
  /// blob is not a dev wrapper (fail closed — caller drops the envelope).
  (String, String)? _devUnwrap(String wire) {
    try {
      final decoded = jsonDecode(utf8.decode(base64Decode(wire)));
      if (decoded is Map<String, dynamic>) {
        final from = decoded['from'];
        final ct = decoded['ct'];
        if (from is String && ct is String) return (from, ct);
      }
    } catch (_) {/* not a dev wrapper */}
    return null;
  }

  Future<void> _drainPending() async {
    if (_wiped) return;
    final queued = List<_PendingSend>.from(_pending.values);
    for (final p in queued) {
      if (_relay.currentState != RelayConnectionState.connected) break;
      p.attempts++;
      try {
        await _relay.sendMessage(
          recipientId: p.recipientId,
          ciphertextB64: p.ciphertextB64,
          sealed: true,
        );
        _pending.remove(p.messageId);
        _log('drained pending id=${_redactId(p.messageId)}');
      } catch (e) {
        _log(
          'retry failed attempt=${p.attempts} :: ${e.runtimeType}',
        );
      }
    }
  }

  Future<String> _ensureConversation(String peerId) async {
    // The listed SecureDatabase API exposes only getConversations() for
    // reads, so we filter client-side. Conversation lists are bounded by
    // the number of peers a user actually talks to — typically tens, not
    // thousands — so the linear scan is acceptable.
    final all = await _db.getConversations();
    for (final c in all) {
      if (c.recipientId == peerId) return c.id;
    }
    final id = _uuid.v4();
    await _db.insertConversation(Conversation(
      id: id,
      recipientId: peerId,
      // Placeholder; the real identity key is pinned by the session
      // init flow.
      recipientPublicKey: '',
      lastMessageAt: DateTime.now().toUtc(),
    ));
    return id;
  }

  Future<void> panicWipe() async {
    _wiped = true;
    _log('panic wipe initiated');

    await _incomingSub?.cancel();
    _incomingSub = null;
    await _stateSub?.cancel();
    _stateSub = null;

    try {
      await _relay.wipeAndDisconnect();
    } catch (_) {/* swallow */}

    try {
      await _sessions.wipeAllSessions();
    } catch (_) {/* swallow */}

    try {
      await _prekeys.wipeAll();
    } catch (_) {/* swallow */}

    // Wipe the relay-auth keypair between prekeys and the DB. Sequencing
    // matters: prekeys must drop first (so no fresh PreKey bundle can be
    // posted under the old auth key), and the DB wipe follows so any
    // queued outbound that referenced the relay session can't be replayed
    // after a key rotation. Identity goes last regardless — see below.
    try {
      await _relayAuth.wipeRelayAuth();
    } catch (_) {/* swallow */}

    try {
      await _db.wipeDatabase();
    } catch (_) {/* swallow */}

    try {
      await _identity.wipeIdentity();
    } catch (_) {/* swallow */}

    _pending.clear();
    _seenMessageIds.clear();
    if (!_decryptedController.isClosed) {
      await _decryptedController.close();
    }
    _log('panic wipe complete');
  }

  String _contentHashId(Uint8List bytes) {
    final hash = SHA256Digest().process(bytes);
    final truncated = hash.sublist(0, 16);
    return base64Url.encode(truncated).replaceAll('=', '');
  }

  String _redactId(String id) {
    if (id.length <= 8) return '<id:short>';
    return '${id.substring(0, 6)}…';
  }

  void _log(String message) {
    // SECURITY: never plaintext, never ciphertext bytes, never key material.
    // Use _redactId() for IDs. Log `e.runtimeType` not `e.toString()`.
    // ignore: avoid_print
    print('[MessageService] $message');
  }
}
