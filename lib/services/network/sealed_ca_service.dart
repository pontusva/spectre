import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/crypto/sealed_sender.dart';

/// Thrown when the sealed-sender CA key cannot be obtained or — worse — the
/// relay returns a key that differs from the one we pinned. Callers MUST fail
/// closed: a changed CA key means either a relay compromise or a MITM, and we
/// must never trust sender certificates signed by an unpinned key.
class SealedCaException implements Exception {
  final String message;
  const SealedCaException(this.message);

  @override
  String toString() => 'SealedCaException: $message';
}

/// Fetches and TOFU-pins the relay's sealed-sender CA public key, then hands
/// back a [SealedSender] bound to it.
///
/// Trust model: the relay is the certificate authority and is UNTRUSTED for
/// sender *authentication* (see the doc on [SealedSender]). Pinning the CA key
/// on first use does NOT make sender attribution trustworthy — that still
/// requires out-of-band fingerprint verification — but it does stop a relay
/// from later swapping the CA key to one whose private half a third party
/// holds, and it makes a key change a loud, fail-closed event rather than a
/// silent downgrade.
///
/// The CA public key is public by definition, so it is fetched over plain
/// (unauthenticated) HTTP, mirroring [PrekeyService.fetchBundle]. It is pinned
/// in [FlutterSecureStorage] only so a later mismatch is detectable; secrecy
/// is not the point.
class SealedCaService {
  static const String _kPinKey = 'spectre.sealed_ca_pub';
  static const int _kCaKeyLen = 32;

  final Uri _relayUrl;
  final FlutterSecureStorage _storage;

  /// Out-of-band CA pins, keyed by canonical domain → raw 32-byte CA pubkey.
  /// When a domain is present here, its key is ABSOLUTE: the network fetch is
  /// never trusted to override it, the value is never overwritten, and a
  /// served key that disagrees fails closed. This is the R3-2 mitigation that
  /// removes the relay's ability to be its own pinned authority — ship the
  /// CA key in the build (e.g. --dart-define=SPECTRE_SEALED_CA=<domain>:<b64>)
  /// so a fresh install does NOT TOFU-trust whatever the relay first serves,
  /// and so the relay cannot use CA rotation as a network-wide kill switch
  /// for these domains. Empty by default (pure TOFU, dev posture).
  final Map<String, Uint8List> _oobPins;

  SealedCaService({
    required Uri relayUrl,
    FlutterSecureStorage? storage,
    Map<String, Uint8List>? outOfBandPins,
  })  : _relayUrl = relayUrl,
        _oobPins = outOfBandPins ?? const <String, Uint8List>{},
        _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
                resetOnError: false,
              ),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
                synchronizable: false,
              ),
            );

  /// Parses a build-time out-of-band CA pin spec into a domain→key map.
  /// Format: comma-separated `domain:base64key` entries, e.g.
  /// `relay.example:AbC...=,backup.example:XyZ...=`. Malformed entries are
  /// skipped (a bad pin must not brick boot); a wrong-length key is dropped.
  /// Intended to be fed from `String.fromEnvironment('SPECTRE_SEALED_CA')`.
  static Map<String, Uint8List> parseOobPins(String raw) {
    final out = <String, Uint8List>{};
    if (raw.trim().isEmpty) return out;
    for (final entry in raw.split(',')) {
      final i = entry.lastIndexOf(':');
      if (i <= 0 || i >= entry.length - 1) continue;
      final domain = entry.substring(0, i).trim().toLowerCase();
      final b64 = entry.substring(i + 1).trim();
      if (domain.isEmpty) continue;
      try {
        final bytes = base64Decode(b64);
        if (bytes.length != _kCaKeyLen) continue;
        out[domain] = bytes;
      } catch (_) {
        // skip malformed key
      }
    }
    return out;
  }

  /// Returns the pinned CA key for the given domain.
  ///
  /// Resolution order:
  ///   1. OUT-OF-BAND pin (build config): absolute. Returned without a fetch;
  ///      a network key that disagrees is irrelevant (and if fetched, must
  ///      match or we fail closed). The relay cannot rotate or kill-switch a
  ///      domain pinned this way — R3-2's structural fix.
  ///   2. TOFU pin (first-use): fetch `GET /sealed-ca`, validate length, pin.
  ///   3. Subsequent runs: fetch again and compare to the pinned value.
  ///        - identical → ok.
  ///        - DIFFERENT but the response carries a rotation proof
  ///          (prev_public_key == our pin AND rotation_sig verifies under the
  ///          pin over the new key) → adopt the new key and re-pin. This is a
  ///          SIGNED rotation: the relay proved possession of the OLD private
  ///          key, so it is not the silent-swap / kill-switch case.
  ///        - DIFFERENT with no valid proof → [SealedCaException], pin
  ///          nothing new (possible compromise / MITM / unsigned rotation).
  /// If the network fetch fails but we have a pinned (or OOB) key, proceed
  /// with it (offline-tolerant).
  Future<Uint8List> getCaKeyForDomain(String domain) async {
    final canonical = domain.toLowerCase();
    final oob = _oobPins[canonical];
    final pinKey = '$_kPinKey.$canonical';
    final pinned = oob ?? await _loadPinned(pinKey);

    _SealedCaResponse? fetched;
    try {
      fetched = await _fetchCaKey(canonical);
    } catch (_) {
      // Network/parse failure. If we already have a pinned (or OOB) key, use
      // it; the CA key is long-lived and pinned, so a transient fetch failure
      // must not block sealed messaging. With nothing pinned, fail closed.
      if (pinned == null) {
        throw SealedCaException('CA key unavailable and none pinned for $canonical');
      }
      return pinned;
    }

    // Out-of-band pin is authoritative: never overwrite it, and a served key
    // that disagrees is a red flag we surface rather than trust.
    if (oob != null) {
      if (!_bytesEqual(oob, fetched.publicKey)) {
        throw SealedCaException(
            'served CA key disagrees with out-of-band pin for $canonical');
      }
      return oob;
    }

    if (pinned == null) {
      await _storage.write(key: pinKey, value: base64Encode(fetched.publicKey));
      return fetched.publicKey;
    }

    if (_bytesEqual(pinned, fetched.publicKey)) {
      return pinned;
    }

    // Pinned-vs-served mismatch. Only acceptable via a SIGNED rotation: the
    // response must carry a proof that the holder of the key we ALREADY
    // trust authorised this new key. Anything else (no proof, prev key isn't
    // ours, bad signature) is a silent swap / kill-switch attempt — fail
    // closed and keep the old pin.
    if (_rotationProofValid(pinned: pinned, resp: fetched)) {
      await _storage.write(key: pinKey, value: base64Encode(fetched.publicKey));
      return fetched.publicKey;
    }

    throw SealedCaException('CA key changed without valid rotation proof for $canonical');
  }

  /// Verifies a signed CA rotation: prev_public_key must equal the key we
  /// already pinned, and rotation_sig must be a valid Ed25519 signature by
  /// that pinned key over the NEW public key bytes. Any missing/malformed
  /// field returns false (fail closed) — an unsigned change is never adopted.
  bool _rotationProofValid({
    required Uint8List pinned,
    required _SealedCaResponse resp,
  }) {
    final prev = resp.prevPublicKey;
    final sig = resp.rotationSig;
    if (prev == null || sig == null) return false;
    // The proof must chain from the EXACT key we trust today.
    if (!_bytesEqual(prev, pinned)) return false;
    try {
      return ed.verify(ed.PublicKey(pinned), resp.publicKey, sig);
    } catch (_) {
      return false;
    }
  }

  Future<Uint8List?> _loadPinned(String pinKey) async {
    final stored = await _storage.read(key: pinKey);
    if (stored == null) return null;
    try {
      final bytes = base64Decode(stored);
      if (bytes.length != _kCaKeyLen) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<_SealedCaResponse> _fetchCaKey(String domain) async {
    final url = _httpUrlForDomain(domain);
    final client = HttpClient();
    try {
      final req = await client.getUrl(url);
      // Bound the fetch so a black-hole relay can't stall app bring-up.
      final resp = await req.close().timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        throw SealedCaException('relay status ${resp.statusCode}');
      }
      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) {
        throw const SealedCaException('malformed sealed-ca response');
      }
      final pub = json['public_key'];
      if (pub is! String) {
        throw const SealedCaException('sealed-ca missing public_key');
      }
      final bytes = base64Decode(pub);
      if (bytes.length != _kCaKeyLen) {
        throw const SealedCaException('sealed-ca key bad length');
      }
      // Optional signed-rotation fields. Tolerated as absent; validated only
      // for length here (signature check happens in _rotationProofValid).
      Uint8List? prevPub;
      Uint8List? rotSig;
      final prevRaw = json['prev_public_key'];
      final sigRaw = json['rotation_sig'];
      if (prevRaw is String && prevRaw.isNotEmpty) {
        try {
          final p = base64Decode(prevRaw);
          if (p.length == _kCaKeyLen) prevPub = p;
        } catch (_) {/* ignore malformed proof field */}
      }
      if (sigRaw is String && sigRaw.isNotEmpty) {
        try {
          final sgn = base64Decode(sigRaw);
          if (sgn.length == 64) rotSig = sgn;
        } catch (_) {/* ignore malformed proof field */}
      }
      return _SealedCaResponse(
        publicKey: bytes,
        prevPublicKey: prevPub,
        rotationSig: rotSig,
      );
    } on SocketException catch (e) {
      throw SealedCaException('network: ${e.osError?.errorCode ?? 0}');
    } finally {
      client.close(force: false);
    }
  }

  /// ws:// -> http://, wss:// -> https://
  Uri _httpUrlForDomain(String domain) {
    final scheme = switch (_relayUrl.scheme) {
      'wss' => 'https',
      'ws' => 'http',
      _ => _relayUrl.scheme,
    };
    return Uri.parse('$scheme://$domain/sealed-ca');
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// Parsed `/sealed-ca` response: the current CA public key plus the optional
/// signed-rotation proof (previous public key + Ed25519 signature over the
/// new key, made by the previous key). The proof fields are null when the
/// relay serves a first-generation key.
class _SealedCaResponse {
  final Uint8List publicKey;
  final Uint8List? prevPublicKey;
  final Uint8List? rotationSig;

  const _SealedCaResponse({
    required this.publicKey,
    required this.prevPublicKey,
    required this.rotationSig,
  });
}
