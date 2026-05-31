import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';
import 'package:uuid/uuid.dart';

import '../core/crypto/identity_manager.dart';
import '../core/crypto/prekey_manager.dart';
import '../core/crypto/relay_auth_manager.dart';
import '../core/crypto/sealed_sender.dart';
import '../core/crypto/session_manager.dart';
import '../core/models/contact.dart';
import '../core/models/conversation.dart';
import '../core/models/message.dart';
import '../core/storage/secure_database.dart';
import 'network/prekey_service.dart';
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
class DecryptedMessage {
  final String id;
  final String senderId;
  final String conversationId;
  final String plaintext;
  final DateTime timestamp;

  /// True when the peer's Signal identity key DIFFERS from the one previously
  /// pinned for this conversation (a key change since first contact). The UI
  /// should surface this prominently and prompt re-verification: a key change
  /// is exactly what a relay-as-CA MITM or an account takeover looks like, and
  /// the sender certificate alone cannot distinguish it from a legitimate
  /// reinstall. False on first contact (nothing pinned yet) and on a match.
  final bool senderKeyChanged;

  const DecryptedMessage({
    required this.id,
    required this.senderId,
    required this.conversationId,
    required this.plaintext,
    required this.timestamp,
    this.senderKeyChanged = false,
  });
}

/// Outcome of comparing a peer's current session identity key against the key
/// pinned for their conversation. Pure decision (see
/// [MessageService.decideIdentityPin]) so it is unit-testable without a DB.
enum IdentityPinDecision {
  /// Nothing pinned yet — TOFU: store the current key.
  pinFirstUse,

  /// Current key equals the pinned key — all good.
  matched,

  /// Current key DIFFERS from the pinned key — surface loudly, do not silently
  /// re-pin. The human must re-verify the fingerprint out of band.
  changed,
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

  // Sealed Sender. Outgoing messages are sealed with seal(); incoming ones are
  // opened with open() + the C2 identity binding. Null only when the relay CA
  // could not be pinned this run (or in tests); then send queues and receive
  // fails closed (drops) — there is NO unsealed fallback path.
  final SealedSender? _sealed;

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

  /// RAM-only plaintext cache, keyed by message id, so a chat that is left and
  /// reopened still shows already-decrypted text within a single app run.
  ///
  /// SECURITY POSTURE — read before touching: plaintext is NEVER written to
  /// disk; this map lives only in process memory and is cleared on [panicWipe]
  /// and lost on process death. It DOES mean decrypted text now survives
  /// backgrounding/foregrounding (a relaxation of the original "nothing
  /// plaintext survives the next foreground" stance) in exchange for the app
  /// being usable as a messenger. Stored ratchet ciphertext can never be
  /// re-decrypted (the Double Ratchet is one-time), so without this cache
  /// history is permanently unreadable after navigating away. If you need
  /// history to survive a restart, that requires persisting plaintext in the
  /// SQLCipher-encrypted DB — a separate, larger disk-posture decision.
  final Map<String, String> _plaintextCache = <String, String>{};

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
    SealedSender? sealedSender,
    Uuid? uuid,
  })  : _identity = identityManager,
        _prekeys = preKeyManager,
        _sessions = sessionManager,
        _db = database,
        _relay = relayService,
        _relayAuth = relayAuthManager,
        _prekeyService = prekeyService,
        _sealed = sealedSender,
        _uuid = uuid ?? const Uuid() {
    // Announce the sealed-sender state once at startup, so a build that
    // couldn't pin the relay CA (sealed sender unavailable) is obvious rather
    // than silently dropping every message.
    _log(_sealed != null
        ? 'sealed sender: ACTIVE (authenticated cert, no sender on the wire)'
        : 'sealed sender: UNAVAILABLE (relay CA not pinned — messaging disabled '
            'until reachable)');
    _incomingSub = _relay.incoming.listen(_onRelayFrame);
    _stateSub = _relay.connectionState.listen((state) {
      if (state == RelayConnectionState.connected) {
        unawaited(_drainPending());
      }
    });
  }

  Stream<DecryptedMessage> get decryptedMessages =>
      _decryptedController.stream;

  /// Returns the RAM-cached plaintext for [messageId] decrypted earlier this
  /// session, or null if it isn't cached (older message, or post-restart —
  /// the UI then shows the ciphertext placeholder). Disk is never consulted;
  /// see [_plaintextCache].
  String? cachedPlaintext(String messageId) => _plaintextCache[messageId];

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

    // The local DB always stores the inner ratchet ciphertext, never the wire
    // form. The sealed-sender blob is built at delivery time by [_deliver] so
    // a send that can't be sealed yet — no session identity or no sender
    // certificate — is queued and resealed on the next drain, never sent
    // unsealed.
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

    // RAM-only: keep our own sent text readable when the chat is reopened
    // this session. Keyed by the DB row id so _loadHistory can recover it.
    _plaintextCache[messageId] = plaintext;

    try {
      await _deliver(recipientId, ciphertextB64);
      return MessageStatus.sent;
    } catch (e) {
      _pending[messageId] = _PendingSend(
        messageId: messageId,
        recipientId: recipientId,
        ciphertextB64: ciphertextB64,
        timestamp: now,
      );
      _log('send not delivered -> pending :: ${e.runtimeType}');
      return MessageStatus.pending;
    }
  }

  /// Builds the on-wire form for [innerCtB64] and hands it to the relay.
  /// Throws on any failure (relay offline, no session identity, no sender
  /// certificate, seal error) so the caller queues for retry. Critically, the
  /// sealed path NEVER falls back to sending an unsealed envelope — failing
  /// closed is the whole point of sealed sender.
  Future<void> _deliver(String recipientId, String innerCtB64) async {
    final wireCtB64 = await _sealForWire(recipientId, innerCtB64);
    await _relay.sendMessage(
      recipientId: recipientId,
      ciphertextB64: wireCtB64,
      sealed: true,
    );
  }

  /// Produces the base64 sealed-sender blob for [innerCtB64]. Throws if any
  /// prerequisite is missing so [_deliver] can queue rather than leak.
  Future<String> _sealForWire(String recipientId, String innerCtB64) async {
    final sealed = _sealed;
    if (sealed == null) {
      throw StateError('sealed sender not configured');
    }
    // Recipient identity key from the established session — no prekey-bundle
    // refetch, so no one-time prekey is burned per message.
    final recipientIdentityKey = await _sessions.remoteIdentityKey(recipientId);
    if (recipientIdentityKey == null) {
      throw StateError('no session identity for recipient yet');
    }
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final cert = await _relay.ensureSenderCert(nowMs: nowMs);
    if (cert == null) {
      throw StateError('sender certificate unavailable');
    }
    final blob = await sealed.seal(
      recipientId: recipientId,
      recipientIdentityKey: recipientIdentityKey,
      certBytes: cert.cert,
      certSignature: cert.sig,
      innerCiphertextB64: innerCtB64,
    );
    return base64Encode(blob);
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

    // The ciphertext field is a Sealed Sender blob: open it with our identity
    // key to recover the AUTHENTICATED sender id and the inner ratchet
    // ciphertext. There is NO sender_id fallback — a frame we cannot open is
    // dropped (fail closed). If sealed sender isn't configured (relay CA not
    // pinned this run), there is no authenticated way to attribute an inbound
    // message, so we drop it rather than trust the wire.
    final sealed = _sealed;
    if (sealed == null) {
      _log('dropped envelope: sealed sender not configured');
      return;
    }
    final Uint8List blob;
    try {
      blob = base64Decode(rawCiphertext);
    } catch (_) {
      _log('dropped envelope: sealed blob not base64');
      return;
    }
    final identity = await _identity.loadOrCreate();
    final OpenedSealed opened;
    try {
      opened = await sealed.open(
        ownIdentityKeyPair: identity.identityKeyPair,
        blob: blob,
        recipientId: identity.userId,
        // H2: replay is guarded below by the persistent message-id dedup.
        // Remaining minor follow-up — expiry trusts the device clock (no
        // trusted offline time source); acceptable, documented in review.
        nowMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      );
    } catch (e) {
      // Any malformed/forged/expired sealed envelope. Fail closed; log the
      // runtime type only, never the blob bytes or cert fields.
      _log('dropped sealed envelope :: ${e.runtimeType}');
      return;
    }
    // C2: bind the certified sender identity to the identity key inside a
    // first-contact PreKey message BEFORE any decrypt/session init, so a
    // hostile relay cannot staple a valid cert onto someone else's message.
    try {
      SessionManager.assertFirstContactIdentity(
        opened.innerCiphertextB64,
        opened.senderIdentityKeyRaw,
      );
    } catch (e) {
      _log('dropped sealed envelope: identity binding :: ${e.runtimeType}');
      return;
    }
    final senderId = opened.senderId;
    final ciphertextB64 = opened.innerCiphertextB64;

    final ciphertextBytes = Uint8List.fromList(utf8.encode(ciphertextB64));
    final messageId = _contentHashId(ciphertextBytes);

    // Dedup / replay gate (H2). Two layers:
    //   * _seenMessageIds — fast in-memory path within a session.
    //   * _db.messageExists — PERSISTENT guard so a relay replaying an old
    //     sealed envelope after a restart (when the in-memory set is empty) is
    //     still dropped before we re-decrypt or re-notify. The id is a content
    //     hash of the ciphertext, so a replay maps to the same id.
    // Done before decrypt so a replayed PreKey can't re-drive session setup.
    if (_seenMessageIds.contains(messageId) ||
        await _db.messageExists(messageId)) {
      _seenMessageIds.add(messageId);
      _log(
        'duplicate/replayed inbound from ${_redactId(senderId)} '
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

    // RAM-only: keep this decrypted text readable if the chat is reopened
    // this session (the stored ciphertext can never be re-decrypted).
    _plaintextCache[messageId] = plaintext;

    // TOFU-pin the peer identity key and detect a change. Best-effort: a
    // failure here must NEVER block delivery of an already-decrypted message,
    // so the whole thing is wrapped and defaults to "not changed".
    var senderKeyChanged = false;
    try {
      senderKeyChanged = await _checkAndPinIdentity(conversationId, senderId);
    } catch (e) {
      _log('identity pin check failed :: ${e.runtimeType}');
    }

    if (!_decryptedController.isClosed) {
      _decryptedController.add(DecryptedMessage(
        id: messageId,
        senderId: senderId,
        conversationId: conversationId,
        plaintext: plaintext,
        timestamp: timestamp,
        senderKeyChanged: senderKeyChanged,
      ));
    }
  }

  /// Pure pin decision — no I/O — so it is directly unit-testable.
  /// [storedB64] is the conversation's pinned key ('' if none yet);
  /// [currentB64] is the peer's current session identity key.
  static IdentityPinDecision decideIdentityPin(
    String storedB64,
    String currentB64,
  ) {
    if (storedB64.isEmpty) return IdentityPinDecision.pinFirstUse;
    if (storedB64 == currentB64) return IdentityPinDecision.matched;
    return IdentityPinDecision.changed;
  }

  /// TOFU-pins the peer's identity key for [conversationId] and reports whether
  /// it CHANGED from a previously-pinned value.
  ///
  /// The key compared is the one libsignal pinned in the session store (via
  /// [SessionManager.remoteIdentityKey]) — the actual ratchet identity, not the
  /// relay-attested certificate field — so this catches a relay swapping the
  /// peer's identity key across sessions even though the (relay-issued) cert
  /// would still verify. The pinned value lives in the conversation row and
  /// survives restarts, while the in-memory session does not, which is exactly
  /// what makes cross-session change detection possible.
  ///
  /// On a change we mark the contact unverified (so the existing
  /// contact-verification UI reflects it) and return true so the caller flags
  /// the message; we deliberately do NOT silently re-pin — the human must
  /// re-verify out of band. Returns false on first use and on a match.
  Future<bool> _checkAndPinIdentity(
    String conversationId,
    String senderId,
  ) async {
    final key = await _sessions.remoteIdentityKey(senderId);
    if (key == null) return false; // no session identity to pin yet
    final serialized = key.serialize();
    final currentB64 = base64Encode(serialized);

    String stored = '';
    for (final c in await _db.getConversations()) {
      if (c.id == conversationId) {
        stored = c.recipientPublicKey;
        break;
      }
    }

    final decision = decideIdentityPin(stored, currentB64);
    if (decision == IdentityPinDecision.matched) return false;

    // First use OR a change: (re)pin the conversation key and (re)build the
    // peer's contact record from the CURRENT key so the fingerprint-
    // verification UI has the right safety number to compare, always starting
    // UNVERIFIED. A change is additionally surfaced loudly (return true ->
    // chat banner): we adopt the new key for message continuity but never
    // silently — the human must re-verify out of band.
    await _db.updateConversationKey(conversationId, currentB64);
    await _upsertPeerContact(senderId, serialized);

    if (decision == IdentityPinDecision.changed) {
      _log(
        'SECURITY: peer identity key CHANGED for ${_redactId(senderId)} '
        '— re-pinned, contact reset to unverified, prompting re-verification',
      );
      return true;
    }
    return false;
  }

  /// Creates or refreshes the peer's contact record from their identity key,
  /// resetting it to UNVERIFIED. The fingerprint is SHA-256 over the serialized
  /// identity public key, hex-encoded — derived identically to the local
  /// fingerprint in contact_screen, so the two devices' safety numbers line up.
  /// Reuses the existing row's id (the userId column is UNIQUE) so a change
  /// updates in place rather than violating the constraint.
  Future<void> _upsertPeerContact(
    String userId,
    Uint8List serializedKey,
  ) async {
    final hash = SHA256Digest().process(serializedKey);
    final fpHex =
        hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final existing = await _db.getContact(userId);
    await _db.insertContact(Contact(
      id: existing?.id ?? _uuid.v4(),
      userId: userId,
      identityKeyFingerprint: fpHex,
      createdAt: existing?.createdAt ?? DateTime.now().toUtc(),
      displayName: existing?.displayName,
      isVerified: false,
    ));
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

  Future<void> _drainPending() async {
    if (_wiped) return;
    final queued = List<_PendingSend>.from(_pending.values);
    for (final p in queued) {
      if (_relay.currentState != RelayConnectionState.connected) break;
      p.attempts++;
      try {
        // p.ciphertextB64 is the inner ratchet ciphertext; _deliver reseals it
        // with a current certificate at drain time.
        await _deliver(p.recipientId, p.ciphertextB64);
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
    _plaintextCache.clear();
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
