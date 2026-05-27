import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/crypto/identity_manager.dart';

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
///   * The client signs the nonce with the device's long-term
///     [IdentityKeyPair] private half (Curve25519) and replies with
///     `(user_id, public_identity_key, signature)`.
///   * The server verifies the signature against the supplied public
///     key, then checks that the public key matches the one it has on
///     file for `user_id` (or, on first contact, pins it).
///   * Nothing crosses the wire that could be replayed against another
///     server, and nothing is stored on disk that an attacker who
///     dumps the device could use to log in as us forever. The only
///     long-lived secret is the identity private key, which is in the
///     Keystore and is the same key we already trust for E2E.
class RelayService {
  /// Maximum number of automatic reconnect attempts before we give up
  /// and surface a `failed` state. The user can then manually retry —
  /// silent unbounded reconnection is a battery and metadata leak.
  static const int _kMaxReconnectAttempts = 5;
  static const Duration _kInitialReconnectDelay = Duration(seconds: 1);
  static const Duration _kAuthTimeout = Duration(seconds: 10);

  final Uri _relayUrl;
  final IdentityManager _identityManager;
  final Random _rng = Random();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  Completer<void>? _authCompleter;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _wiped = false;
  RelayConnectionState _state = RelayConnectionState.disconnected;

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
  })  : _relayUrl = relayUrl,
        _identityManager = identityManager;

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
      _setState(RelayConnectionState.connected);
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

    final type = msg['type'];
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
      default:
        // Unknown frame type — forward-compatible behavior is to
        // ignore. A logging hook here would be a metadata leak.
        break;
    }
  }

  Future<void> _respondToChallenge(Map<String, dynamic> challenge) async {
    try {
      final nonceB64 = challenge['nonce'];
      if (nonceB64 is! String) {
        throw const FormatException('challenge missing nonce');
      }
      final nonce = base64Decode(nonceB64);

      final identity = await _identityManager.loadOrCreate();

      // Sign the server's nonce with our Curve25519 identity private
      // key. The server verifies against the public key we include in
      // the response (and against its own pinned copy of that key for
      // this user_id, if any). No bearer tokens, no passwords — the
      // only credential is possession of the key that already roots
      // every Signal session for this device.
      final signature = Curve.calculateSignature(
        identity.identityKeyPair.getPrivateKey(),
        nonce,
      );

      final response = <String, Object>{
        'type': 'auth',
        'user_id': identity.userId,
        'identity_key': base64Encode(
          identity.identityKeyPair.getPublicKey().serialize(),
        ),
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
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
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
      await _channel?.sink.close(ws_status.normalClosure);
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
      await _channel?.sink.close(ws_status.goingAway);
    } catch (_) {/* ignore */}
    _channel = null;
    _authCompleter = null;
    _setState(RelayConnectionState.disconnected);
    if (!_incomingController.isClosed) {
      await _incomingController.close();
    }
    if (!_stateController.isClosed) {
      await _stateController.close();
    }
  }
}
