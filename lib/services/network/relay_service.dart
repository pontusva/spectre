import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/crypto/identity_manager.dart';
import '../../core/crypto/relay_auth_manager.dart';
import 'prekey_service.dart';

/// Coarse state of the relay connection, surfaced to the UI so it can
/// show a "reconnecting…" banner instead of failing silently.
enum RelayConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed,
}

/// WebSocket client for the Spectre relay.
///
/// What the relay is for: ferrying encrypted blobs between two clients
/// that may not be online at the same time. It is INTENTIONALLY a dumb
/// store-and-forward — it never sees plaintext, and with sealed sender
/// it doesn't even see who sent a message.
///
/// What the relay can ALWAYS see, regardless of sealed sender:
///   * The client's IP address. Sealed sender hides the sender ID at
///     the application layer, but the TCP/TLS connection still has a
///     source IP. Defending against this requires a network-layer
///     mitigation (Tor, an onion-routed transport, or shared anonymous
///     egress) and is out of scope for this class.
///   * The recipient ID. The relay must know who to deliver to. The
///     recipient is therefore the one piece of routing metadata that
///     leaks to the server by construction. The mitigation at this
///     layer is to make recipient IDs unlinkable to real identities —
///     hence the rule that user IDs are random base64url, never PII.
///   * Connection timing and message size. Even an encrypted, sealed
///     envelope reveals its byte count and the moment it was uploaded.
///     Padding messages to fixed bucket sizes and using cover traffic
///     are higher-layer mitigations and are not implemented here.
///   * The user's authenticated identity at connect time (see
///     authentication note below). After auth, every action on the
///     socket is implicitly attributable to that account — which is
///     why authenticated upload of a sealed envelope is a metadata
///     leak. Real sealed-sender deployments upload over a SEPARATE
///     anonymous connection per send; this class handles only the
///     authenticated control channel and the inbound delivery stream.
///
/// Authentication design (no passwords, no tokens):
///   * On TCP connect the server sends a one-time random nonce.
///   * The client signs the nonce with a dedicated **relay-auth**
///     Ed25519 private key (see [RelayAuthManager]) and replies with
///     `(user_id, identity_public_key, signature)`.
///   * The server verifies the signature against the supplied public
///     key, then checks that the public key matches the one it has on
///     file for `user_id` (or, on first contact, pins it).
///   * Nothing crosses the wire that could be replayed against another
///     server, and nothing is stored on disk that an attacker who
///     dumps the device could use to log in as us forever.
///   * The relay-auth key is INTENTIONALLY separate from the libsignal
///     IdentityKeyPair: libsignal's identity is Curve25519/XEdDSA, and
///     the Go relay verifies plain Ed25519 (golang.org/x/crypto has
///     no XEdDSA support). Decoupling also gives us domain separation:
///     a relay-auth key compromise does not compromise Signal sessions.
class RelayService {
  /// Maximum number of automatic reconnect attempts before we give up
  /// and surface a `failed` state. The user can then manually retry —
  /// silent unbounded reconnection is a battery and metadata leak.
  static const int _kMaxReconnectAttempts = 5;
  static const Duration _kInitialReconnectDelay = Duration(seconds: 1);
  static const Duration _kAuthTimeout = Duration(seconds: 10);

  /// How long to wait for a `sender_cert` reply after asking for one.
  static const Duration _kCertTimeout = Duration(seconds: 10);

  /// Re-request a sender certificate this far before its `exp`, so a send is
  /// never sealed with a cert that expires in-flight before the recipient
  /// opens it.
  static const int _kCertRefreshMarginMs = 60 * 60 * 1000; // 1h

  final Uri _relayUrl;
  final IdentityManager _identityManager;
  final RelayAuthManager _relayAuthManager;
  final Random _rng = Random();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  Completer<void>? _authCompleter;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _wiped = false;
  RelayConnectionState _state = RelayConnectionState.disconnected;

  // Sealed Sender certificate, issued by the relay over the authed WS and
  // cached in memory only (re-requested each cold start, consistent with the
  // forensic-resistance model — nothing cert-related is persisted). The cert
  // binds our authenticated userID to our Signal identity key for a bounded
  // window; the sender staples it inside every sealed envelope.
  Uint8List? _certBytes;
  Uint8List? _certSig;
  int? _certExpMs;
  Completer<void>? _certCompleter;

  // PrekeyService is wired in AFTER construction via attachPrekeyService.
  // The two services have a mutual dependency — PrekeyService needs the
  // RelayService to send control frames, RelayService needs the
  // PrekeyService to publish on auth — and constructor-injecting the
  // RelayService into PrekeyService is the half of the cycle that's
  // natural to express in Dart. We close the cycle with this setter
  // instead of late-init so a test or alternate composition can opt out
  // entirely (passing null is fine; uploadBundle just won't run).
  PrekeyService? _prekeyService;

  final StreamController<Map<String, dynamic>> _incomingController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<RelayConnectionState> _stateController =
      StreamController<RelayConnectionState>.broadcast();

  /// [relayUrl] is intentionally injected — there is NO hardcoded
  /// endpoint. The user (or operator) configures it at app startup so
  /// the same binary can be pointed at a community-run relay, a Tor
  /// onion service, or a self-hosted instance without recompilation.
  RelayService({
    required Uri relayUrl,
    required IdentityManager identityManager,
    required RelayAuthManager relayAuthManager,
  })  : _relayUrl = relayUrl,
        _identityManager = identityManager,
        _relayAuthManager = relayAuthManager;

  /// Inbound messages from the relay, already JSON-decoded. The UI
  /// layer subscribes here to feed [SessionManager.decryptMessage].
  Stream<Map<String, dynamic>> get incoming => _incomingController.stream;

  /// Connection state transitions — drive UI banners off this.
  Stream<RelayConnectionState> get connectionState =>
      _stateController.stream;

  RelayConnectionState get currentState => _state;

  /// Opens the WebSocket and completes the signed-nonce auth handshake.
  /// Subsequent disconnects trigger automatic reconnection with
  /// exponential backoff (see [_scheduleReconnect]).
  Future<void> connect() async {
    if (_wiped) {
      throw StateError('RelayService has been wiped — construct a new one');
    }
    _reconnectAttempts = 0;
    await _doConnect();
  }

  Future<void> _doConnect() async {
    _setState(RelayConnectionState.connecting);
    try {
      _channel = WebSocketChannel.connect(_relayUrl);
      _authCompleter = Completer<void>();

      // Await the WebSocket upgrade BEFORE listening. connect() is lazy: a
      // failed handshake — host down, connection refused, or a server that
      // answers HTTP but never upgrades (e.g. a wrong path) — surfaces on
      // `ready`. If we don't consume it here, that same error ALSO completes
      // the sink's `done` future, which nothing awaits, and Dart reports it
      // as an unhandled zone exception (the "not upgraded to websocket"
      // crash). Awaiting it inside this try routes the failure straight to
      // the catch below, which tears down and reconnects like any other drop.
      // Bounded by the auth timeout so a black-hole host can't hang connect.
      await _channel!.ready.timeout(_kAuthTimeout);

      // Belt-and-suspenders: the sink's done future also completes with the
      // terminal socket error on a later drop. Attach a no-op handler so a
      // late error can't surface unhandled after teardown. Reconnect is still
      // driven by the stream's onError/onDone below, not by this future.
      unawaited(_channel!.sink.done.catchError((_) {}));

      _channelSub = _channel!.stream.listen(
        _handleFrame,
        onError: _handleStreamError,
        onDone: _handleStreamDone,
        // Don't cancelOnError — we want both onError and onDone to
        // fire so reconnect logic runs consistently regardless of
        // which fires first.
        cancelOnError: false,
      );
      await _authCompleter!.future.timeout(_kAuthTimeout);
      _reconnectAttempts = 0;

      // CRITICAL ORDERING — DO NOT REARRANGE.
      //
      // _state MUST be `connected` before we hand control off to
      // uploadBundle. sendControlFrame gates on `_state == connected`
      // and silently drops frames otherwise. If the state assignment
      // ran after the unawaited dispatch, uploadBundle's
      // register_prekeys frame would be eaten on the very first
      // connect of every cold start — exactly the race we observed
      // in the field. We inline the assignment here (rather than
      // routing through _setState) so a future refactor that swaps
      // _setState for something async cannot quietly reintroduce
      // the race; the synchronous write is right above the dispatch
      // and lexically impossible to reorder.
      _state = RelayConnectionState.connected;
      if (!_stateController.isClosed) {
        _stateController.add(_state);
      }

      // Now safe to fire-and-forget the bundle publish: _state is
      // committed, so any sendControlFrame inside uploadBundle will
      // be admitted. unawaited because a slow keystore read should
      // not block the connect() Future — re-uploading on every
      // reconnect makes the operation self-healing if any single
      // attempt fails.
      final ps = _prekeyService;
      if (ps != null) {
        unawaited(ps.uploadBundle().then((_) async {
          // Warm the sealed-sender certificate on the SAME connection, right
          // after the prekey bundle. The relay reads WS frames in order, so
          // issuing request_sender_cert AFTER register_prekeys guarantees the
          // bundle is registered before the cert is minted — eliminating the
          // cold-start race where the first send would otherwise wait out the
          // cert timeout (issueSenderCert needs the bundle to exist). The cert
          // lands in the cache so the first real send seals immediately.
          // Best-effort: on failure the lazy request inside the send path is
          // the fallback, and the next reconnect re-warms.
          await ensureSenderCert(
            nowMs: DateTime.now().toUtc().millisecondsSinceEpoch,
          );
        }).catchError((_) {
          // Swallow: neither the bundle publish nor the cert warm-up should
          // surface as a connect error. The next reconnect retries both.
        }));
      }
    } catch (_) {
      // Any error during connect or auth — schedule a retry. We
      // deliberately do not surface the specific error reason on the
      // public state stream: distinguishing "TLS failed" from "auth
      // rejected" is useful for debugging but, if logged or shown,
      // can become a metadata side-channel.
      await _teardownChannel();
      _scheduleReconnect();
    }
  }

  void _handleFrame(dynamic raw) {
    final Map<String, dynamic> msg;
    try {
      if (raw is! String) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      msg = decoded;
    } catch (_) {
      // Malformed frame from the relay. Drop silently — a hostile
      // relay should not be able to crash the client by sending
      // garbage.
      return;
    }

    // The Go relay's protocol does NOT tag frames with a `type` field —
    // Challenge is `{"nonce":...}`, AuthResponse is `{"success":...,"error":...}`,
    // and delivered messages carry envelope fields. Dispatch by shape:
    // whichever required field is present tells us what stage of the
    // handshake we're in. The legacy `type`-based cases below remain as
    // a fallback for forward compatibility with a future tagged variant.
    final type = msg['type'];
    if (type == null) {
      if (msg.containsKey('nonce')) {
        unawaited(_respondToChallenge(msg));
        return;
      }
      if (msg.containsKey('success')) {
        final ok = msg['success'] == true;
        if (!(_authCompleter?.isCompleted ?? true)) {
          if (ok) {
            _authCompleter!.complete();
          } else {
            _authCompleter!.completeError(
              StateError('relay rejected authentication'),
            );
          }
        }
        return;
      }
      if (msg.containsKey('ciphertext') || msg.containsKey('recipient_id')) {
        if (!_incomingController.isClosed) {
          _incomingController.add(msg);
        }
        return;
      }
      return;
    }
    switch (type) {
      case 'challenge':
        unawaited(_respondToChallenge(msg));
        break;
      case 'auth_ok':
        if (!(_authCompleter?.isCompleted ?? true)) {
          _authCompleter!.complete();
        }
        break;
      case 'auth_failed':
        if (!(_authCompleter?.isCompleted ?? true)) {
          _authCompleter!.completeError(
            StateError('relay rejected authentication'),
          );
        }
        break;
      case 'message':
        if (!_incomingController.isClosed) {
          _incomingController.add(msg);
        }
        break;
      case 'sender_cert':
        _handleSenderCert(msg);
        break;
      default:
        // Unknown frame type — forward-compatible behavior is to
        // ignore. A logging hook here would be a metadata leak.
        break;
    }
  }

  /// Caches a `sender_cert` reply. The relay marshals the cert and signature
  /// as Go `[]byte`, which JSON-encode as base64 strings. The cert is itself
  /// canonical JSON `{uid, ik, exp}`; we read `exp` so we can refresh before
  /// it lapses. Always completes any pending [ensureSenderCert] waiter — even
  /// on malformed input, so the waiter falls through to "no cert" rather than
  /// hanging until timeout.
  void _handleSenderCert(Map<String, dynamic> msg) {
    try {
      final certB64 = msg['cert'];
      final sigB64 = msg['signature'];
      if (certB64 is! String || sigB64 is! String) {
        return;
      }
      final cert = base64Decode(certB64);
      final sig = base64Decode(sigB64);
      final certJson = jsonDecode(utf8.decode(cert));
      if (certJson is! Map<String, dynamic> || certJson['exp'] is! num) {
        return;
      }
      _certBytes = cert;
      _certSig = sig;
      _certExpMs = (certJson['exp'] as num).toInt();
    } catch (_) {
      // Leave the cache untouched on any parse failure; the waiter resolves
      // to "no cert available" below.
    } finally {
      if (!(_certCompleter?.isCompleted ?? true)) {
        _certCompleter!.complete();
      }
    }
  }

  /// Returns a currently-valid sender certificate (bytes + signature),
  /// requesting a fresh one over the authed WS if the cache is empty or close
  /// to expiry. Returns null if the relay is not connected or does not reply
  /// in time — the caller MUST then queue/fail the send rather than fall back
  /// to an unsealed path. [nowMs] is the caller's clock for the expiry check.
  Future<({Uint8List cert, Uint8List sig})?> ensureSenderCert({
    required int nowMs,
  }) async {
    final cert = _certBytes;
    final sig = _certSig;
    final exp = _certExpMs;
    if (cert != null &&
        sig != null &&
        exp != null &&
        nowMs < exp - _kCertRefreshMarginMs) {
      return (cert: cert, sig: sig);
    }

    if (_state != RelayConnectionState.connected) {
      return null;
    }

    // Coalesce concurrent requests: only emit one request frame while a reply
    // is outstanding; additional callers await the same completer.
    if (_certCompleter == null || _certCompleter!.isCompleted) {
      _certCompleter = Completer<void>();
      _channel?.sink.add(jsonEncode(<String, Object>{
        'type': 'request_sender_cert',
      }));
    }

    try {
      await _certCompleter!.future.timeout(_kCertTimeout);
    } catch (_) {
      return null;
    }

    final newCert = _certBytes;
    final newSig = _certSig;
    if (newCert != null && newSig != null) {
      return (cert: newCert, sig: newSig);
    }
    return null;
  }

  Future<void> _respondToChallenge(Map<String, dynamic> challenge) async {
    try {
      final nonceB64 = challenge['nonce'];
      if (nonceB64 is! String) {
        throw const FormatException('challenge missing nonce');
      }
      final nonce = base64Decode(nonceB64);

      // user_id comes from IdentityManager: it is the addressable handle
      // on the relay and is shared with the Signal identity. The
      // Ed25519 keypair used to AUTHENTICATE that handle, however,
      // comes from RelayAuthManager — independent of Signal sessions.
      // See RelayAuthManager for the rationale (libsignal uses
      // XEdDSA/Curve25519 which the Go relay cannot verify).
      final identity = await _identityManager.loadOrCreate();
      final signature = await _relayAuthManager.sign(nonce);
      final identityPublicKey = await _relayAuthManager.publicKeyBase64();

      // The relay's AuthRequest struct has no `type` field — it
      // identifies the frame by the stage of the conversation, not by
      // a tagged-union discriminator. Sending an extra `type` is
      // harmless (Go's json decoder ignores unknown fields by default)
      // but we omit it so the wire shape is exactly what the server
      // contract specifies.
      final response = <String, Object>{
        'user_id': identity.userId,
        // Field name matches the relay's AuthRequest.IdentityPublicKey
        // (json tag `identity_public_key`). Renaming this here without
        // updating the relay would silently break auth on every device.
        'identity_public_key': identityPublicKey,
        'signature': base64Encode(signature),
      };

      _channel?.sink.add(jsonEncode(response));
    } catch (e) {
      if (!(_authCompleter?.isCompleted ?? true)) {
        _authCompleter!.completeError(e);
      }
    }
  }

  /// Uploads a ciphertext envelope to the relay for delivery to
  /// [recipientId].
  ///
  /// When [sealed] is true the envelope intentionally OMITS sender_id.
  /// The whole point of sealed sender is that the relay learns the
  /// recipient and the bytes, but not who sent them. Including a
  /// sender_id field here — even an empty one — would defeat the
  /// purpose, because the relay could correlate it with the
  /// authenticated session at TCP level. In a production deployment
  /// the sealed-sender upload should happen over a separate,
  /// unauthenticated connection so the TCP-level identity isn't a
  /// silent fallback. Callers are responsible for routing sealed
  /// envelopes through that anonymous channel; this method just
  /// guarantees the envelope payload itself carries no sender claim.
  ///
  /// When [sealed] is false (e.g. delivery receipts, typing
  /// indicators that don't merit metadata protection), sender_id is
  /// included for the relay's routing logic.
  Future<void> sendMessage({
    required String recipientId,
    required String ciphertextB64,
    required bool sealed,
  }) async {
    if (_state != RelayConnectionState.connected) {
      throw StateError('relay not connected');
    }

    final envelope = <String, Object>{
      'type': 'message',
      'recipient_id': recipientId,
      'ciphertext': ciphertextB64,
      'sealed': sealed,
      // Field name matches the relay's SealedEnvelope/OpenEnvelope
      // `timestamp_ms` json tag. Sending `timestamp` (the old name) left the
      // relay's TimestampMS at 0, so delivered messages showed as epoch 1970.
      'timestamp_ms': DateTime.now().toUtc().millisecondsSinceEpoch,
    };

    if (!sealed) {
      // Only attach the sender ID for non-sealed envelopes. This
      // branch exists for control-plane messages where metadata
      // protection is not the priority; for actual chat messages
      // [sealed] must be true.
      final identity = await _identityManager.loadOrCreate();
      envelope['sender_id'] = identity.userId;
    }

    _channel?.sink.add(jsonEncode(envelope));
  }

  /// Wires the PrekeyService that will be invoked after each successful
  /// auth handshake. Pass null to detach (used by tests). Safe to call
  /// before [connect]; the reference is consulted at auth-complete time.
  void attachPrekeyService(PrekeyService? service) {
    _prekeyService = service;
  }

  /// Sends a structured control frame over the authenticated WebSocket.
  /// Used by PrekeyService for register_prekeys; intentionally a thin
  /// pass-through so this class doesn't need to grow per-control-type
  /// methods. Callers MUST only invoke this after the connection has
  /// reached [RelayConnectionState.connected]; sending before auth
  /// completes will either be dropped by the relay or rejected.
  ///
  /// Frames are JSON-encoded as-is. No automatic `type` injection —
  /// the caller controls the wire shape so this stays usable for the
  /// (currently tagged) control plane and any future untagged frames.
  void sendControlFrame(Map<String, Object?> frame) {
    if (_state != RelayConnectionState.connected) {
      // Silent drop. Surfacing an error here would let timing of
      // control-frame failures become a side channel; the next
      // reconnect's post-auth hook will re-run uploadBundle anyway.
      return;
    }
    _channel?.sink.add(jsonEncode(frame));
  }

  void _handleStreamError(Object error, StackTrace _) {
    if (!(_authCompleter?.isCompleted ?? true)) {
      _authCompleter!.completeError(error);
    }
    _scheduleReconnect();
  }

  void _handleStreamDone() {
    if (!(_authCompleter?.isCompleted ?? true)) {
      _authCompleter!.completeError(
        StateError('relay closed during auth'),
      );
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_wiped) return;
    // Coalesce: if a reconnect is already pending, don't stack another.
    if (_reconnectTimer?.isActive ?? false) return;

    if (_reconnectAttempts >= _kMaxReconnectAttempts) {
      _setState(RelayConnectionState.failed);
      return;
    }
    _reconnectAttempts++;

    // Exponential backoff with bounded jitter. Jitter is important —
    // without it, every client in a fleet that disconnected together
    // (e.g. a relay restart) would retry in lockstep and produce a
    // thundering-herd timing signature visible to a network observer.
    final baseMs =
        _kInitialReconnectDelay.inMilliseconds * (1 << (_reconnectAttempts - 1));
    final jitterMs = _rng.nextInt((baseMs ~/ 4) + 1);
    final delay = Duration(milliseconds: baseMs + jitterMs);

    _setState(RelayConnectionState.reconnecting);
    _reconnectTimer = Timer(delay, () {
      unawaited(_doConnect());
    });
  }

  Future<void> _teardownChannel() async {
    await _channelSub?.cancel();
    _channelSub = null;
    try {
      unawaited(_channel?.sink.close(ws_status.normalClosure).catchError((_) {}));
    } catch (_) {
      // Best effort — the underlying socket may already be gone.
    }
    _channel = null;
    _authCompleter = null;
  }

  void _setState(RelayConnectionState s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  /// Gracefully closes the connection without disabling future
  /// reconnects. Use this when the app goes to the background.
  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _teardownChannel();
    _setState(RelayConnectionState.disconnected);
  }

  /// Panic-wipe integration. Closes the socket, cancels pending
  /// reconnects, and closes the public streams. After this call the
  /// instance is unusable — the app must rebuild a new [RelayService]
  /// once a fresh identity exists. We do NOT auto-reconnect on a
  /// wiped service: a panic-wipe means the identity it was
  /// authenticating with is being destroyed, and reconnecting with a
  /// stale (or absent) identity would either fail noisily on the
  /// server or, worse, silently re-register the new identity against
  /// the old account.
  Future<void> wipeAndDisconnect() async {
    _wiped = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    try {
      await _channelSub?.cancel();
    } catch (_) {/* ignore */}
    _channelSub = null;
    try {
      unawaited(_channel?.sink.close(ws_status.goingAway).catchError((_) {}));
    } catch (_) {/* ignore */}
    _channel = null;
    _authCompleter = null;
    // Drop the cached sender certificate with the rest of the session state.
    _certBytes = null;
    _certSig = null;
    _certExpMs = null;
    _certCompleter = null;
    _setState(RelayConnectionState.disconnected);
    if (!_incomingController.isClosed) {
      await _incomingController.close();
    }
    if (!_stateController.isClosed) {
      await _stateController.close();
    }
  }
}
