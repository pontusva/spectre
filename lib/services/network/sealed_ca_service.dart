import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  SealedCaService({
    required Uri relayUrl,
    FlutterSecureStorage? storage,
  })  : _relayUrl = relayUrl,
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

  /// Returns a [SealedSender] bound to the pinned CA key.
  ///
  /// On first run, fetches `GET /sealed-ca`, validates the key length, and
  /// pins it (TOFU). On subsequent runs, fetches again and compares to the
  /// pinned value: a match returns a [SealedSender]; a MISMATCH throws
  /// [SealedCaException] and pins nothing new. If the network fetch fails but
  /// we have a pinned key, we proceed with the pinned key (offline-tolerant)
  /// — the pin is the security anchor, not the fetch.
  Future<SealedSender> sealedSender() async {
    final pinned = await _loadPinned();

    Uint8List? fetched;
    try {
      fetched = await _fetchCaKey();
    } catch (_) {
      // Network/parse failure. If we already have a pinned key, use it; the
      // CA key is long-lived and pinned, so a transient fetch failure must
      // not block sealed messaging. With no pinned key there is nothing to
      // fall back to — fail closed.
      if (pinned == null) {
        throw const SealedCaException('CA key unavailable and none pinned');
      }
      return SealedSender(caPublicKey: pinned);
    }

    if (pinned == null) {
      await _storage.write(key: _kPinKey, value: base64Encode(fetched));
      return SealedSender(caPublicKey: fetched);
    }

    if (!_bytesEqual(pinned, fetched)) {
      // Pinned-vs-served mismatch: possible relay compromise / MITM. Do not
      // update the pin, do not trust the new key. Surface a generic error.
      throw const SealedCaException('CA key changed since first use');
    }
    return SealedSender(caPublicKey: pinned);
  }

  Future<Uint8List?> _loadPinned() async {
    final stored = await _storage.read(key: _kPinKey);
    if (stored == null) return null;
    try {
      final bytes = base64Decode(stored);
      if (bytes.length != _kCaKeyLen) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> _fetchCaKey() async {
    final url = _httpUrlFor('/sealed-ca');
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
      return bytes;
    } on SocketException catch (e) {
      throw SealedCaException('network: ${e.osError?.errorCode ?? 0}');
    } finally {
      client.close(force: false);
    }
  }

  /// ws:// -> http://, wss:// -> https:// (mirrors PrekeyService._httpUrlFor),
  /// so the same relay URL config works for both the WS control channel and
  /// the public HTTP key endpoints.
  Uri _httpUrlFor(String path) {
    final scheme = switch (_relayUrl.scheme) {
      'wss' => 'https',
      'ws' => 'http',
      _ => _relayUrl.scheme,
    };
    return _relayUrl.replace(scheme: scheme, path: path);
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
