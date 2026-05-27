import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../core/crypto/identity_manager.dart';
import '../core/crypto/prekey_manager.dart';
import '../core/crypto/session_manager.dart';
import '../core/models/message.dart';
import '../core/storage/secure_database.dart';
import 'network/relay_service.dart';

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
/// If the UI needs to render the message again later, it must
/// re-decrypt from the ciphertext row. The cost of a re-decrypt is
/// nothing compared to the cost of a forensic finding showing
/// plaintext in a persisted state container.
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

/// Orchestrator that ties the crypto, storage, and transport layers
/// together. The UI talks to this class; this class talks to the
/// individual managers. Splitting orchestration out of the underlying
/// components keeps each component independently auditable.
class MessageService {
  final IdentityManager _identity;
  final PreKeyManager _prekeys;
  final SessionManager _sessions;
  final SecureDatabase _db;
  final RelayService _relay;

  final Uuid _uuid;
  final StreamController<DecryptedMessage> _decryptedController =
      StreamController<DecryptedMessage>.broadcast();

  /// In-memory only. By design this queue is lost on process death and
  /// on [panicWipe]. Persisting pending sends to disk would defeat the
  /// "nothing plaintext-adjacent survives a wipe" property — the
  /// ciphertext itself is already in the encrypted DB, so a retry can
  /// be reconstructed from there if we ever decide to persist this.
  final Map<String, _PendingSend> _pending = <String, _PendingSend>{};

  StreamSubscription<Map<String, dynamic>>? _incomingSub;
  StreamSubscription<RelayConnectionState>? _stateSub;
  bool _wiped = false;

  MessageService({
    required IdentityManager identityManager,
    required PreKeyManager preKeyManager,
    required SessionManager sessionManager,
    required SecureDatabase database,
    required RelayService relayService,
    Uuid? uuid,
  })  : _identity = identityManager,
        _prekeys = preKeyManager,
        _sessions = sessionManager,
        _db = database,
        _relay = relayService,
        _uuid = uuid ?? const Uuid() {
    _incomingSub = _relay.incoming.listen(_onRelayFrame);
    _stateSub = _relay.connectionState.listen((state) {
      if (state == RelayConnectionState.connected) {
        unawaited(_drainPending());
      }
    });
  }

  /// Stream of just-decrypted messages. The UI is the ONLY consumer.
  /// Do not pipe this into any caching layer.
  Stream<DecryptedMessage> get decryptedMessages =>
      _decryptedController.stream;

  /// Encrypts [plaintext] for [recipientId], persists the resulting
  /// ciphertext to the encrypted DB, and attempts delivery via the
  /// relay. If the relay is offline, the send is queued in-memory and
  /// retried on next [RelayConnectionState.connected].
  Future<MessageStatus> sendMessage(
    String recipientId,
    String plaintext,
  ) async {
    if (_wiped) {
      throw StateError('MessageService has been wiped');
    }

    // Step 1: encrypt. If we can't encrypt (no session yet, no
    // identity, etc.) we MUST NOT persist anything — the user should
    // see the failure immediately rather than have a "pending" item
    // sit in the UI that can never go out.
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

    // Step 2: persist ciphertext. We store the ENVELOPE BYTES — i.e.
    // the UTF-8 bytes of the base64 string produced by SessionManager.
    // No plaintext touches the DB layer. The schema's BLOB NOT NULL
    // column would reject a NULL/plaintext mistake at write time.
    final ciphertextBytes = Uint8List.fromList(utf8.encode(ciphertextB64));
    try {
      final db = await _db.open();
      await db.insert(
        'messages',
        Message(
          id: messageId,
          conversationId: conversationId,
          senderId: identity.userId,
          ciphertext: ciphertextBytes,
          timestamp: now,
          isRead: true,
        ).toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    } catch (e) {
      _log('persist failed :: ${e.runtimeType}');
      return MessageStatus.failed;
    }

    // Step 3: deliver. Offline-tolerance is handled by queueing rather
    // than retrying inline (so the UI doesn't block on a flaky link).
    if (_relay.currentState != RelayConnectionState.connected) {
      _pending[messageId] = _PendingSend(
        messageId: messageId,
        recipientId: recipientId,
        ciphertextB64: ciphertextB64,
        timestamp: now,
      );
      _log('queued pending send id=${_redactId(messageId)}');
      return MessageStatus.pending;
    }

    try {
      await _relay.sendMessage(
        recipientId: recipientId,
        ciphertextB64: ciphertextB64,
        // Default to sealed sender. Non-sealed must be an explicit,
        // narrow opt-in (control plane only).
        sealed: true,
      );
      return MessageStatus.sent;
    } catch (e) {
      _pending[messageId] = _PendingSend(
        messageId: messageId,
        recipientId: recipientId,
        ciphertextB64: ciphertextB64,
        timestamp: now,
      );
      _log('send failed -> pending :: ${e.runtimeType}');
      return MessageStatus.pending;
    }
  }

  /// Called for every inbound envelope. Public so it can be unit-tested
  /// without spinning up a real relay; in production it's wired
  /// internally to [RelayService.incoming].
  Future<void> receiveMessage(Map<String, dynamic> envelope) async {
    if (_wiped) return;

    final ciphertextB64 = envelope['ciphertext'];
    final sealed = envelope['sealed'] == true;
    final senderIdRaw = envelope['sender_id'];
    final timestampMs = envelope['timestamp'];

    if (ciphertextB64 is! String || timestampMs is! int) {
      _log('dropped envelope: malformed');
      return;
    }

    // Sealed-sender envelopes carry no sender_id at this layer. The
    // SealedSessionCipher unwrap step (not implemented yet — see
    // SessionManager class doc) is responsible for producing the
    // resolved sender_id before reaching here. If we get a sealed
    // envelope with no resolved sender, fail closed: dropping is
    // safer than guessing.
    if (senderIdRaw is! String) {
      _log('dropped envelope: no resolved sender (sealed=$sealed)');
      return;
    }
    final senderId = senderIdRaw;

    final ciphertextBytes = Uint8List.fromList(utf8.encode(ciphertextB64));

    // Idempotent message ID: SHA-256 over the ciphertext. Two distinct
    // sends produce distinct ratchet outputs, so distinct ciphertexts,
    // so distinct hashes. A duplicate delivery of the same envelope
    // (e.g. server retry, reconnect replay) produces the same hash and
    // is rejected at DB insert time by the PRIMARY KEY constraint.
    final messageId = _contentHashId(ciphertextBytes);

    final conversationId = await _ensureConversation(senderId);

    // Decrypt BEFORE persisting so a bad ciphertext doesn't leave a
    // dangling row that no later flow can interpret.
    final String plaintext;
    try {
      plaintext = await _sessions.decryptMessage(senderId, ciphertextB64);
    } catch (e) {
      _log(
        'decrypt failed from ${_redactId(senderId)} :: ${e.runtimeType}',
      );
      return;
    }

    final timestamp =
        DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true);

    final db = await _db.open();
    final inserted = await db.insert(
      'messages',
      Message(
        id: messageId,
        conversationId: conversationId,
        senderId: senderId,
        ciphertext: ciphertextBytes,
        timestamp: timestamp,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    // ConflictAlgorithm.ignore returns 0 when the row already existed —
    // that's our dedup signal. We don't re-emit the DecryptedMessage in
    // that case (the UI already showed it on the first delivery).
    if (inserted == 0) {
      _log(
        'duplicate inbound from ${_redactId(senderId)} '
        'id=${_redactId(messageId)} ignored',
      );
      return;
    }

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
    // The RelayService only emits `type: message` frames on its
    // `incoming` stream; auth/control frames are consumed internally.
    // We still defensively check here so a future relay-frame schema
    // change can't silently feed control data into the decrypt path.
    if (envelope['type'] != 'message') return;
    await receiveMessage(envelope);
  }

  Future<void> _drainPending() async {
    if (_wiped) return;
    // Snapshot before iterating — _pending can be mutated during the
    // loop by concurrent send/wipe calls.
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
        // Leave in the queue for the next reconnect cycle.
      }
    }
  }

  Future<String> _ensureConversation(String peerId) async {
    final db = await _db.open();
    final existing = await db.query(
      'conversations',
      columns: <String>['id'],
      where: 'recipient_id = ?',
      whereArgs: <Object>[peerId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return existing.first['id'] as String;
    }
    final id = _uuid.v4();
    await db.insert('conversations', <String, Object?>{
      'id': id,
      'recipient_id': peerId,
      // Placeholder. The real public key is pinned by the session
      // init flow (SessionManager.initializeSession verifies the
      // SignedPreKey signature against it). A conversation created
      // here from an inbound PreKeySignalMessage gets its key filled
      // in by that flow before any safety-number verification UI
      // would surface.
      'recipient_public_key': Uint8List(0),
      'last_message_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      'is_archived': 0,
    });
    return id;
  }

  /// Orchestrated panic wipe across every layer this service composes.
  ///
  /// Order matters and is enforced here:
  ///   1. RelayService — disconnect FIRST. We do not want any
  ///      in-flight delivery receipts or background sends to fire
  ///      after the user has asked to be wiped (they would leak
  ///      "this user is wiping right now" metadata).
  ///   2. SessionManager — drop ratchet state. Any partially-decoded
  ///      inbound message now fails fast instead of producing
  ///      plaintext.
  ///   3. PreKeyManager — destroy one-time prekeys and SignedPreKeys.
  ///      A peer who fetched our bundle before wipe can no longer
  ///      establish a session against the old prekeys.
  ///   4. SecureDatabase — wipe the encrypted DB and destroy the
  ///      SQLCipher key. After this point, on-disk ciphertext is
  ///      cryptographically unrecoverable.
  ///   5. IdentityManager — destroy the long-term identity. This is
  ///      done LAST because every earlier step might transitively
  ///      need to load the identity (e.g. relay teardown signing a
  ///      final goodbye frame). Doing it last keeps each prior step
  ///      well-defined.
  Future<void> panicWipe() async {
    _wiped = true;
    _log('panic wipe initiated');

    await _incomingSub?.cancel();
    _incomingSub = null;
    await _stateSub?.cancel();
    _stateSub = null;

    // Best-effort across every step. A failure in one step must not
    // skip the next — losing the relay disconnect is bad, but losing
    // the identity wipe is much worse.
    try {
      await _relay.wipeAndDisconnect();
    } catch (_) {/* swallow */}

    try {
      await _sessions.wipeAllSessions();
    } catch (_) {/* swallow */}

    try {
      await _prekeys.wipeAll();
    } catch (_) {/* swallow */}

    try {
      await _db.wipeDatabase();
    } catch (_) {/* swallow */}

    try {
      await _identity.wipeIdentity();
    } catch (_) {/* swallow */}

    _pending.clear();
    if (!_decryptedController.isClosed) {
      await _decryptedController.close();
    }
    _log('panic wipe complete');
  }

  // ---------------------------------------------------------------------
  // Logging — single chokepoint for redaction review.
  // ---------------------------------------------------------------------

  /// 16-byte SHA-256-truncated, base64url-no-pad. A natural,
  /// dedup-friendly identifier. NOT used as a security boundary —
  /// the actual cryptographic guarantees come from the Signal
  /// session, not from this ID.
  String _contentHashId(Uint8List bytes) {
    final hash = SHA256Digest().process(bytes);
    final truncated = hash.sublist(0, 16);
    return base64Url.encode(truncated).replaceAll('=', '');
  }

  /// Renders an ID safely for logs. Even though our IDs are random
  /// (no PII), the FULL ID is a stable handle that can be cross-
  /// referenced with relay logs or crash reports to deanonymize a
  /// user. Show a short prefix only.
  String _redactId(String id) {
    if (id.length <= 8) return '<id:short>';
    return '${id.substring(0, 6)}…';
  }

  /// Logging chokepoint. The rule for every call site:
  ///   * NEVER pass plaintext message content.
  ///   * NEVER pass raw ciphertext bytes (length alone is a side-channel
  ///     when the attacker also has timing).
  ///   * NEVER pass key material, signatures, or fingerprints.
  ///   * Use [_redactId] for any user-, message-, or conversation-ID.
  ///   * For exceptions, log `e.runtimeType` not `e.toString()` — many
  ///     exception messages embed the input that triggered them.
  ///
  /// Logs may be siphoned by crash reporters, vendor SDKs, or platform
  /// log aggregators. Treat every line as potentially world-readable.
  void _log(String message) {
    // ignore: avoid_print
    print('[MessageService] $message');
  }
}
