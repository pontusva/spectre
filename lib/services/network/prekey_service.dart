import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../../core/crypto/identity_manager.dart';
import '../../core/crypto/prekey_manager.dart';
import 'relay_service.dart';

/// PrekeyService brokers prekey-bundle exchange with the Spectre relay.
///
/// Two responsibilities, deliberately separated by transport:
///   * uploadBundle() — pushes THIS device's public prekey material to
///     the relay over the EXISTING authenticated WebSocket. We piggyback
///     on the authenticated channel because writes carry an implicit
///     ownership claim: only the WS-authenticated userID can replace the
///     bundle stored under that userID. An anonymous HTTP POST could not
///     bind the publish to a specific account without re-implementing
///     auth at the HTTP layer.
///   * fetchBundle() — pulls a PEER's bundle over plain HTTP. Bundles
///     contain only public keys, so this endpoint is intentionally
///     unauthenticated. Putting the fetch on its own connection also
///     avoids burning the WS handshake's auth budget on a path where
///     the authenticated identity is irrelevant.
///
/// Forward-secrecy reminder: every fetchBundle() consumes one one-time
/// prekey on the relay. The relay's atomicity guarantee is what gives
/// the first message in a fresh X3DH handshake its initial-message
/// forward-secrecy property — see PrekeyStore on the relay side.
class PrekeyService {
  // Hard cap on OTPKs uploaded in a single bundle. Mirrors the relay's
  // maxOneTimePrekeys constant; uploading more would just be silently
  // truncated server-side and waste battery on the wire.
  static const int _kMaxUploadedOneTimePrekeys = 100;

  // Default deviceId and registrationId used when reconstructing a peer's
  // PreKeyBundle from the relay response. Spectre is single-device per
  // identity (see SessionManager._kDefaultDeviceId), and the relay's
  // wire format does NOT carry the recipient's registrationId — it isn't
  // cryptographically verified by libsignal's processPreKeyBundle, only
  // recorded in the SessionRecord, so using a placeholder here is safe
  // for the single-device deployment. If we ever add linked devices,
  // both fields must move onto the wire.
  static const int _kAssumedDeviceId = 1;
  static const int _kAssumedRegistrationId = 1;

  final RelayService _relay;
  final PreKeyManager _prekeys;
  final IdentityManager _identity;
  final Uri _relayUrl;

  PrekeyService({
    required RelayService relayService,
    required PreKeyManager preKeyManager,
    required IdentityManager identityManager,
    required Uri relayUrl,
  })  : _relay = relayService,
        _prekeys = preKeyManager,
        _identity = identityManager,
        _relayUrl = relayUrl;

  /// Builds the local prekey bundle and pushes it to the relay over the
  /// authenticated WebSocket. Idempotent: re-uploading replaces the
  /// stored bundle atomically on the server, so calling this on every
  /// successful connect is safe and is what keeps the published OTPK
  /// list close to the locally available set after refills.
  ///
  /// Caller is expected to invoke this AFTER RelayService completes its
  /// auth handshake — the relay accepts register_prekeys only on an
  /// authenticated session.
  Future<void> uploadBundle() async {
    final identity = await _identity.loadOrCreate();
    final signed = await _prekeys.getCurrentSignedPreKey();
    final oneTimes = await _prekeys.getAllPreKeys();

    // ECPublicKey.serialize() returns the libsignal djb-key form (33B:
    // one-byte type tag + 32B Montgomery coordinate). The relay does
    // structural validation at 32 bytes for raw key fields, so strip
    // the type tag before encoding.
    final identityKeyRaw = _stripDjbTypeTag(
      identity.identityKeyPair.getPublicKey().serialize(),
    );
    final signedPreKeyRaw = _stripDjbTypeTag(
      signed.getKeyPair().publicKey.serialize(),
    );

    final otpkPayload = <Map<String, Object>>[];
    for (final p in oneTimes.take(_kMaxUploadedOneTimePrekeys)) {
      otpkPayload.add(<String, Object>{
        'id': p.id,
        'key': base64Encode(
          _stripDjbTypeTag(p.getKeyPair().publicKey.serialize()),
        ),
      });
    }

    _relay.sendControlFrame(<String, Object>{
      'type': 'register_prekeys',
      'bundle': <String, Object>{
        'identity_key': base64Encode(identityKeyRaw),
        'signed_prekey': base64Encode(signedPreKeyRaw),
        'signed_prekey_sig': base64Encode(signed.signature),
        'signed_prekey_id': signed.id,
        'one_time_prekeys': otpkPayload,
      },
    });
  }

  /// Fetches the recipient's prekey bundle from the relay.
  ///
  /// Returns null on 404 (relay has no record of [recipientId] — never
  /// registered). Throws [PrekeyFetchException] on any other failure;
  /// callers should treat a throw as transient and surface a generic
  /// "session unavailable" state rather than the underlying error,
  /// which can be a metadata side-channel.
  ///
  /// On success the relay has atomically consumed one one-time prekey
  /// for us, so this call MUST be followed by a session-init attempt
  /// against the returned bundle; dropping the bundle silently leaks
  /// an OTPK with no benefit.
  Future<PreKeyBundle?> fetchBundle(String recipientId) async {
    final url = _httpUrlFor(recipientId);
    final client = HttpClient();
    try {
      final req = await client.getUrl(url);
      final resp = await req.close();
      if (resp.statusCode == 404) {
        // Drain so the socket can be reused / cleanly closed.
        await resp.drain<void>();
        return null;
      }
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        throw PrekeyFetchException('relay status ${resp.statusCode}');
      }
      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) {
        throw const PrekeyFetchException('malformed bundle');
      }
      return _bundleFromJson(json);
    } on SocketException catch (e) {
      throw PrekeyFetchException('network: ${e.osError?.errorCode ?? 0}');
    } finally {
      client.close(force: false);
    }
  }

  Uri _httpUrlFor(String recipientId) {
    // ws://  -> http://,  wss:// -> https://. Anything else (already
    // http/https, or a non-websocket scheme) we pass through unchanged
    // so a caller can point at a non-TLS dev relay without ceremony.
    final scheme = switch (_relayUrl.scheme) {
      'wss' => 'https',
      'ws' => 'http',
      _ => _relayUrl.scheme,
    };
    return _relayUrl.replace(scheme: scheme, path: '/prekeys/$recipientId');
  }

  /// Reconstructs a libsignal [PreKeyBundle] from the relay's JSON.
  /// Throws on missing/malformed fields — the caller treats a throw as
  /// a fetch error rather than a 404.
  PreKeyBundle _bundleFromJson(Map<String, dynamic> json) {
    final identityKeyB64 = json['identity_key'];
    final signedPreKeyB64 = json['signed_prekey'];
    final signedPreKeySigB64 = json['signed_prekey_sig'];
    if (identityKeyB64 is! String ||
        signedPreKeyB64 is! String ||
        signedPreKeySigB64 is! String) {
      throw const PrekeyFetchException('missing required field');
    }
    // The signed prekey is mandatory and its id MUST survive the round trip
    // — the sender embeds it in the PreKeySignalMessage and the receiver
    // looks up its private half by that exact id. Tolerate a numeric string
    // (a common JSON int/string mismatch across a Go relay) but FAIL LOUD on
    // a genuinely absent/unparseable id rather than silently defaulting to 0:
    // signed prekey ids start at 1 here, so 0 can only mean "the relay did
    // not return the id", which builds a session doomed to throw
    // InvalidKeyIdException("No such signedprekeyrecord! 0") on the receiver.
    final signedPreKeyId = _parseId(json['signed_prekey_id']);
    if (signedPreKeyId == null || signedPreKeyId == 0) {
      throw const PrekeyFetchException(
        'bundle missing signed_prekey_id (relay did not echo it)',
      );
    }

    // Restore the djb type tag (0x05) that the relay strips for
    // wire-compatibility with the Go side. libsignal's Curve.decodePoint
    // expects the tagged form.
    final identityKey = IdentityKey(
      Curve.decodePoint(_prependDjbTypeTag(base64Decode(identityKeyB64)), 0),
    );
    final signedPreKeyPub = Curve.decodePoint(
      _prependDjbTypeTag(base64Decode(signedPreKeyB64)),
      0,
    );
    final signedPreKeySig = base64Decode(signedPreKeySigB64);

    // The relay returns AT MOST one one-time prekey, atomically consumed.
    // Absence is not an error — Signal allows X3DH to proceed without an
    // OTPK, trading the initial-message forward-secrecy leg for liveness.
    int otpkId = 0;
    ECPublicKey? otpkPub;
    final otpk = json['one_time_prekey'];
    if (otpk is Map<String, dynamic>) {
      final idParsed = _parseId(otpk['id']);
      final keyRaw = otpk['key'];
      if (idParsed != null && keyRaw is String) {
        otpkId = idParsed;
        otpkPub = Curve.decodePoint(
          _prependDjbTypeTag(base64Decode(keyRaw)),
          0,
        );
      }
    }

    // libsignal's PreKeyBundle requires a non-null prekey ECPublicKey
    // at construction even when the "no OTPK" fallback applies. When the
    // OTPK is absent, processPreKeyBundle still functions correctly
    // because it inspects the IDs; but to keep the type contract honest
    // we pass the SignedPreKey public key as a stand-in. This matches
    // the pattern used by the upstream libsignal-Java implementation
    // for the OTPK-exhausted case.
    final preKeyPublicForCtor = otpkPub ?? signedPreKeyPub;

    return PreKeyBundle(
      _kAssumedRegistrationId,
      _kAssumedDeviceId,
      otpkId,
      preKeyPublicForCtor,
      signedPreKeyId,
      signedPreKeyPub,
      signedPreKeySig,
      identityKey,
    );
  }

  // Parse a prekey id that may arrive as a JSON number or a numeric string.
  // Returns null when the value is absent or not a non-negative integer.
  static int? _parseId(Object? raw) {
    if (raw is int) return raw;
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  // libsignal serializes ECPublicKeys with a 1-byte type prefix
  // (0x05 = DJB_TYPE). The relay wire format carries raw 32-byte keys
  // (matching what the Go side will hash into X3DH KDFs), so these
  // helpers translate between the two representations.
  static Uint8List _stripDjbTypeTag(Uint8List serialized) {
    if (serialized.length == 33) {
      return Uint8List.fromList(serialized.sublist(1));
    }
    return serialized;
  }

  static Uint8List _prependDjbTypeTag(Uint8List raw) {
    if (raw.length == 32) {
      // 0x05 == Curve.djbType.
      final out = Uint8List(33);
      out[0] = 0x05;
      out.setRange(1, 33, raw);
      return out;
    }
    return raw;
  }
}

/// Distinct exception type so callers can catch fetch-path errors
/// without conflating them with session-init or transport errors
/// downstream.
class PrekeyFetchException implements Exception {
  final String message;
  const PrekeyFetchException(this.message);
  @override
  String toString() => 'PrekeyFetchException: $message';
}
