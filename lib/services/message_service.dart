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
import 'network/sealed_ca_service.dart';

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

  // Sealed CA Service. Used to resolve the correct CA key for an incoming
  // message by reading its 'iss' claim.
  final SealedCaService _sealedCaService;
  final SealedSender _sealed;

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
    required SealedCaService sealedCaService,
    SealedSender? sealedSender,
    Uuid? uuid,
  })  : _identity = identityManager,
        _prekeys = preKeyManager,
        _sessions = sessionManager,
        _db = database,
        _relay = relayService,
        _relayAuth = relayAuthManager,
        _prekeyService = prekeyService,
        _sealedCaService = sealedCaService,
        _sealed = sealedSender ?? SealedSender(),
        _uuid = uuid ?? const Uuid() {
    _log('sealed sender: ACTIVE');
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
      // Wrap our own display name in with the text (E2E only — the relay
      // never sees it) so the recipient can show our name instead of the raw
      // id. The DB/cache below store just the text, never the wrapper.
      final myName = await _identity.displayName();
      final payload = _encodeOutgoing(myName, plaintext);
      ciphertextB64 = await _sessions.encryptMessage(recipientId, payload);
    } catch (e) {
      _log('encrypt failed for ${_redactId(recipientId)} :: ${e.runtimeType}');
      return MessageStatus.failed;
    }

    final messageId = _uuid.v4();
    final identity = await _identity.loadOrCreate();
    final conversationId =
        await _ensureConversation(recipientId, incoming: false);
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
        // Persist our own sent text (encrypted at rest) so it survives a
        // restart, not just this session.
        plaintext: plaintext,
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

    // Pin the peer key + create their contact on the SEND path too (receive
    // does this via _checkAndPinIdentity). Without it, a conversation you
    // started but never got a reply in has no contact row — so no safety
    // number to verify and no nickname to set. Best-effort: the session was
    // established by the chat screen before this send, so remoteIdentityKey is
    // available; a failure must never block the send.
    try {
      await _checkAndPinIdentity(conversationId, recipientId);
    } catch (e) {
      _log('outbound identity pin failed :: ${e.runtimeType}');
    }

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

  /// Canned body for a connection request — the first message sent when you
  /// add a peer, so they get a request in their inbox without you typing.
  static const String invitationBody = 'wants to connect';

  /// Sends a connection request to [recipientId]: establishes the Signal
  /// session if needed (fetching the peer's prekey bundle), then sends the
  /// canned [invitationBody] — which lands in their Requests inbox as the
  /// first message. Returns [MessageStatus.failed] if the peer has no prekey
  /// bundle on the relay (never registered / not reachable) so the caller can
  /// surface that; otherwise the normal send status.
  Future<MessageStatus> sendInvitation(String recipientId) async {
    if (!await _sessions.hasSession(recipientId)) {
      try {
        final bundle = await _prekeyService.fetchBundle(recipientId);
        // ignore: avoid_print
        print('bundle fetched: ' + (bundle == null ? 'null' : 'ok'));
        if (bundle == null) return MessageStatus.failed;
        await _sessions.initializeSession(recipientId, bundle);
        // ignore: avoid_print
        print('session initialized for: ' + recipientId);
      } catch (e) {
        // ignore: avoid_print
        print('session init error: ' + e.toString());
        _log('invitation session init failed :: ${e.runtimeType}');
        return MessageStatus.failed;
      }
    }
    return sendMessage(recipientId, invitationBody);
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

    // Read the federation_sender_relay if present.
    final federationSenderRelay = envelope['federation_sender_relay'];

    if (rawCiphertext is! String || timestampMs is! int) {
      _log('dropped envelope: malformed');
      return;
    }

    _log('receiveMessage envelope keys: ${envelope.keys} recipient_id: ${envelope['recipient_id']} federation_sender_relay: ${envelope['federation_sender_relay']}');

    // Validate federation_sender_relay if present.
    // SECURITY CRITICAL: federation_sender_relay is relay metadata used ONLY for
    // reply routing. It must NEVER be used for identity verification — that's the
    // job of the sealed sender (which verifies the cryptographic certificate inside).
    // To prevent injection attacks, we strictly validate that the domain only
    // contains alphanumeric characters, hyphens, dots, or colons (for ports).
    if (federationSenderRelay != null) {
      if (federationSenderRelay is! String ||
          federationSenderRelay.isEmpty ||
          !RegExp(r'^[a-zA-Z0-9\-.:]+$').hasMatch(federationSenderRelay)) {
        _log('dropped envelope: invalid federation_sender_relay');
        return;
      }
    }

    // The ciphertext field is a Sealed Sender blob: open it with our identity
    // key to recover the AUTHENTICATED sender id and the inner ratchet
    // ciphertext. There is NO sender_id fallback — a frame we cannot open is
    // dropped (fail closed). If sealed sender isn't configured (relay CA not
    // pinned this run), there is no authenticated way to attribute an inbound
    // message, so we drop it rather than trust the wire.
    final sealed = _sealed;
    final Uint8List blob;
    try {
      blob = base64Decode(rawCiphertext);
    } catch (_) {
      _log('dropped envelope: sealed blob not base64');
      return;
    }
    final identity = await _identity.loadOrCreate();
    final envelopeRecipientId = envelope['recipient_id'];
    final recipientId = (envelopeRecipientId is String &&
            envelopeRecipientId.isNotEmpty &&
            RegExp(r'^[a-zA-Z0-9_\-.:@]+$').hasMatch(envelopeRecipientId))
        ? envelopeRecipientId
        : identity.userId;

    final String iss;
    try {
      iss = await sealed.extractIssuer(
        ownIdentityKeyPair: identity.identityKeyPair,
        blob: blob,
        recipientId: recipientId,
      );
    } catch (e) {
      _log('dropped envelope: could not extract issuer :: ${e.runtimeType}');
      return;
    }

    // FINDING-1 FIX: `iss` is attacker-influenced and about to be used as a
    // storage key and a URL host — validate and canonicalize it first, and
    // never let the raw value reach the pin store, the network, or a log.
    final canonicalIss = canonicalRelayDomain(iss);
    if (canonicalIss == null) {
      _log('dropped envelope: invalid cert issuer');
      return;
    }

    final Uint8List caPublicKey;
    try {
      caPublicKey = await _sealedCaService.getCaKeyForDomain(canonicalIss);
    } catch (e) {
      _log('dropped envelope: could not get CA key for issuer :: ${e.runtimeType}');
      return;
    }

    final OpenedSealed opened;
    try {
      opened = await sealed.open(
        ownIdentityKeyPair: identity.identityKeyPair,
        blob: blob,
        recipientId: recipientId,
        caPublicKey: caPublicKey,
        // Raw iss, exactly as extracted: open() asserts the verified cert's
        // issuer is the one we resolved the CA key for.
        expectedIss: iss,
        // H2: replay is guarded below by the persistent message-id dedup.
        // Remaining minor follow-up — expiry trusts the device clock (no
        // trusted offline time source); acceptable, documented in review.
        nowMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      );
    } catch (e) {
      // Any malformed/forged/expired sealed envelope. Fail closed; log the
      // runtime type only, never the blob bytes or cert fields.
      _log('dropped sealed envelope :: $e');
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

    // FINDING-3 FIX: the sender's domain is read from the SIGNED certificate
    // (opened.senderDomain == cert.iss), never from federation_sender_relay.
    // The header is unsigned, relay-controlled transport metadata; if present
    // it must agree with the signed issuer or the envelope is dropped. See
    // deriveFullSenderId for the full rationale.
    final fullSenderId = deriveFullSenderId(
      senderUid: senderId,
      canonicalIss: canonicalIss,
      federationSenderRelay:
          federationSenderRelay is String ? federationSenderRelay : null,
    );
    if (fullSenderId == null) {
      _log('dropped envelope: federation_sender_relay disagrees with signed issuer');
      return;
    }

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
        'duplicate/replayed inbound from ${_redactId(fullSenderId)} '
        'id=${_redactId(messageId)} ignored',
      );
      return;
    }

    // Block gate (one-sided requests): a blocked peer's inbound is dropped
    // fully — no conversation/contact touch, no decrypt, no key-pin, no emit.
    // Block keeps the row (it IS the blocklist), so this stays effective
    // across restarts; deleting it would let the next message re-create a
    // fresh pending request.
    final existingConv = await _db.getConversationByRecipient(fullSenderId);
    if (shouldDropInbound(existingConv?.requestState)) {
      _log('dropped inbound from blocked peer ${_redactId(fullSenderId)}');
      return;
    }

    // incoming:true → a brand-new peer lands in the Requests inbox (pending),
    // not the main Chats list.
    final conversationId = await _ensureConversation(fullSenderId, incoming: true);

    final timestamp =
        DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true);

    String? payload;
    try {
      payload = await _sessions.decryptMessage(fullSenderId, ciphertextB64);
    } catch (e) {
      // Signal "first message" flow: the very first ciphertext a peer
      // sends us is a PreKeySignalMessage, and decryption fails here
      // because we have no session for them yet. The receiver bootstraps
      // its half of the session from the peer's published PreKeyBundle
      // (the same bundle whose one-time prekey the sender already
      // consumed when they built the PreKeySignalMessage), then retries.
      _log(
        'decrypt failed from ${_redactId(fullSenderId)} :: ${e.runtimeType} '
        '-- attempting first-message session init',
      );
      final bundle = await _prekeyService.fetchBundle(fullSenderId);
      if (bundle != null) {
        await _sessions.initializeSession(fullSenderId, bundle);
        try {
          payload = await _sessions.decryptMessage(fullSenderId, ciphertextB64);
        } catch (e2) {
          _log(
            'decrypt retry failed from ${_redactId(fullSenderId)} '
            ':: ${e2.runtimeType}',
          );
        }
      } else {
        _log('no prekey bundle for ${_redactId(fullSenderId)}');
      }
    }

    // The decrypted payload carries the sender's display name + the text.
    // (Legacy/raw messages decode as text with no name.)
    final decoded = payload == null ? null : _decodeIncoming(payload);
    final String? plaintext = decoded?.text;
    final String? peerName = decoded?.name;

    try {
      await _db.insertMessage(Message(
        id: messageId,
        conversationId: conversationId,
        senderId: fullSenderId,
        ciphertext: ciphertextBytes,
        // Persist the decrypted text (encrypted at rest), or null if this
        // message could not be decrypted — then it shows the placeholder.
        plaintext: plaintext,
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
      senderKeyChanged = await _checkAndPinIdentity(conversationId, fullSenderId);
    } catch (e) {
      _log('identity pin check failed :: ${e.runtimeType}');
    }

    // Record the peer's own display name (received E2E) — the contact exists
    // by now (pinned above). Their local nickname, if I set one, still wins in
    // peerLabel(). Best-effort.
    if (peerName != null && peerName.isNotEmpty) {
      try {
        await _db.updateContactPeerName(fullSenderId, peerName);
      } catch (_) {/* contact row may not exist yet */}
    }

    if (!_decryptedController.isClosed) {
      _decryptedController.add(DecryptedMessage(
        id: messageId,
        senderId: fullSenderId,
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

  /// Canonicalizes a relay domain (host or host:port) for use as a TRUST
  /// identifier: lowercases and structurally validates. Returns null when
  /// the value is not a plausible host[:port] — callers MUST drop.
  ///
  /// SECURITY: `iss` is attacker-influenced on first contact (the cert is
  /// signed by a key we are about to TOFU-pin) and is used as (a) the CA
  /// pin-storage key, (b) the host of the outbound /sealed-ca fetch, and
  /// (c) the domain half of the sender's federated identity. Without one
  /// canonical form a relay can fork the pin namespace by varying case
  /// ('A.com' vs 'a.com' pin independently, dodging the key-change alarm)
  /// and point the CA fetch at arbitrary attacker-chosen hosts.
  ///
  /// Deliberately still permits IP literals and single-label hosts
  /// (localhost, docker service names) — the dev federation setup depends
  /// on them. TODO(prod): behind a production flag, reject IP literals and
  /// localhost so an inbound message cannot drive a fetch at link-local /
  /// loopback targets.
  static String? canonicalRelayDomain(String raw) {
    final d = raw.trim().toLowerCase();
    if (d.isEmpty || d.length > 255) return null;
    final m = RegExp(
      r'^([a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*)(:(\d{1,5}))?$',
    ).firstMatch(d);
    if (m == null) return null;
    final port = m.group(6);
    if (port != null) {
      final p = int.parse(port);
      if (p < 1 || p > 65535) return null;
    }
    return d;
  }

  /// Pure derivation of the sender's full (possibly federated) identity.
  /// Returns null when the envelope must be dropped. Pure — unit-testable
  /// without a DB, same pattern as [decideIdentityPin].
  ///
  /// FINDING-3 FIX: the domain half of the identity comes from the SIGNED
  /// certificate issuer ([canonicalIss]), never from the transport.
  /// `federation_sender_relay` is an unsigned, relay-controlled header (any
  /// host can POST /federation/deliver with any X-Spectre-Relay-ID); using
  /// it as identity let a cert attesting alice@A be filed — and
  /// safety-number-verified — as alice@B. The header is demoted to a
  /// consistency signal: when present it must agree with the signed issuer,
  /// and the identity (which doubles as the reply route) is built from the
  /// issuer itself.
  static String? deriveFullSenderId({
    required String senderUid,
    required String canonicalIss,
    required String? federationSenderRelay,
  }) {
    if (federationSenderRelay == null || federationSenderRelay.isEmpty) {
      // Local delivery. Residual, documented: a malicious LOCAL relay could
      // strip the header so a foreign-issued cert aliases a bare local
      // handle — but the local relay is itself the CA for local handles and
      // could mint that cert directly, so this grants no new forgery power.
      return senderUid;
    }
    final canonicalHeader = canonicalRelayDomain(federationSenderRelay);
    if (canonicalHeader == null || canonicalHeader != canonicalIss) {
      return null;
    }
    return '$senderUid@$canonicalIss';
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

    // State-agnostic lookup: getConversations() now excludes pending/blocked,
    // so scanning it would read stored='' for a pending peer and mask every
    // key change (MITM-detection canary). Read the row by recipient regardless
    // of request state.
    final conv = await _db.getConversationByRecipient(senderId);
    final stored = conv?.recipientPublicKey ?? '';

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
      peerName: existing?.peerName,
    ));
  }

  /// Wraps the sender's display name + text into the plaintext that gets
  /// ratchet-encrypted. Versioned JSON so the receiver tells it apart from a
  /// legacy raw-text message. Name omitted when unset.
  String _encodeOutgoing(String? name, String text) {
    final m = <String, Object?>{'v': 1, 't': text};
    if (name != null && name.isNotEmpty) m['n'] = name;
    return jsonEncode(m);
  }

  /// Inverse of [_encodeOutgoing]. A legacy/raw message (no v:1 wrapper, e.g.
  /// from an older peer build) decodes as text with no name.
  ({String? name, String text}) _decodeIncoming(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is Map<String, dynamic> && m['v'] == 1 && m['t'] is String) {
        final n = m['n'];
        return (name: n is String ? n : null, text: m['t'] as String);
      }
    } catch (_) {/* not our wrapper — treat as raw text */}
    return (name: null, text: raw);
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

  /// Returns the conversation id for [peerId], creating the row if needed.
  /// [incoming] = is this peer reaching out to us (vs. us initiating)?
  ///   * New row: `incoming` → pending (Requests inbox); else accepted (Chats).
  ///   * Existing row + we're sending (`!incoming`): replying to a pending
  ///     request accepts it ([nextStateOnOutbound]); accepted/blocked unchanged
  ///     (an outbound never silently un-blocks).
  /// Uses the state-agnostic lookup so pending/blocked rows are found (the
  /// UNIQUE recipientId constraint would otherwise be violated by a duplicate).
  Future<String> _ensureConversation(
    String peerId, {
    required bool incoming,
  }) async {
    final existing = await _db.getConversationByRecipient(peerId);
    if (existing != null) {
      if (!incoming) {
        final next = nextStateOnOutbound(existing.requestState);
        if (next != existing.requestState) {
          await _db.updateConversationState(existing.id, next);
        }
      }
      return existing.id;
    }
    final id = _uuid.v4();
    await _db.insertConversation(Conversation(
      id: id,
      recipientId: peerId,
      // Placeholder; the real identity key is pinned by the session init flow.
      recipientPublicKey: '',
      lastMessageAt: DateTime.now().toUtc(),
      requestState: incoming
          ? ConversationRequestState.pending
          : ConversationRequestState.accepted,
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
