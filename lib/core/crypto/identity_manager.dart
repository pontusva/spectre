import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Manages the long-lived Signal Protocol identity for this device.
///
/// Security design notes:
///   * The IdentityKeyPair is the root of trust for all Signal sessions
///     originated from this device. If it leaks, an attacker can impersonate
///     the user. It therefore never leaves [FlutterSecureStorage], which on
///     Android is backed by the hardware-backed Keystore via
///     EncryptedSharedPreferences.
///   * We deliberately do NOT use phone numbers, email, or any other PII as
///     an account identifier. Activists and journalists must be able to use
///     Spectre without revealing real-world identity to the relay server or
///     to other users. The user ID is a 256-bit random value, base64url
///     encoded, generated locally on first run.
///   * Identity material is regenerated only on explicit panic wipe. We never
///     auto-rotate identity, because doing so silently would break the
///     out-of-band safety-number verification that users rely on to detect
///     MITM.
class IdentityManager {
  // Storage keys. Kept short and opaque so an attacker with read access to
  // the keystore namespace cannot trivially infer the app's purpose.
  static const _kIdentityKeyPair = 'spectre.idkp';
  static const _kRegistrationId = 'spectre.regid';
  static const _kUserId = 'spectre.uid';
  // Optional, user-chosen profile name. Local on this device; transmitted only
  // INSIDE end-to-end-encrypted messages (never to the relay) so contacts can
  // see a name instead of the raw user ID. Not identity material — just a label.
  static const _kDisplayName = 'spectre.dn';

  final FlutterSecureStorage _storage;

  IdentityManager({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // Force EncryptedSharedPreferences so the underlying AES key is
              // generated in and unwrappable only by the Android Keystore.
              // This gives us hardware-backed protection on devices with a
              // TEE/StrongBox, and software-backed AES-GCM elsewhere.
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
                resetOnError: false,
              ),
              // On iOS, only allow access after the first unlock since boot,
              // and never sync to iCloud Keychain (this is local-only key
              // material and must not leave the device).
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
                synchronizable: false,
              ),
            );

  IdentityKeyPair? _cachedIdentityKeyPair;
  int? _cachedRegistrationId;
  String? _cachedUserId;
  String? _cachedDisplayName;
  bool _displayNameLoaded = false;

  /// The user's chosen profile name, or null if unset. Local-only at rest;
  /// see [_kDisplayName]. Cached after first read.
  Future<String?> displayName() async {
    if (_displayNameLoaded) return _cachedDisplayName;
    _cachedDisplayName = await _storage.read(key: _kDisplayName);
    _displayNameLoaded = true;
    return _cachedDisplayName;
  }

  /// Sets (or, with null/empty, clears) the profile name.
  Future<void> setDisplayName(String? name) async {
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      await _storage.delete(key: _kDisplayName);
      _cachedDisplayName = null;
    } else {
      await _storage.write(key: _kDisplayName, value: trimmed);
      _cachedDisplayName = trimmed;
    }
    _displayNameLoaded = true;
  }

  /// Cheap probe used by the router/redirect layer to decide whether
  /// the user is past onboarding. Reads only the identity key entry —
  /// does NOT regenerate anything if absent. Returning false here is
  /// the signal that `loadOrCreate` would generate a fresh identity on
  /// the next call.
  Future<bool> hasIdentity() async {
    if (_cachedIdentityKeyPair != null) return true;
    final raw = await _storage.read(key: _kIdentityKeyPair);
    return raw != null;
  }

  /// Returns the device's long-term identity, generating and persisting it on
  /// first run. Subsequent calls return the loaded identity. Safe to call
  /// from app startup.
  Future<SpectreIdentity> loadOrCreate() async {
    // Fast path: in-memory cache. Avoids hitting the Keystore (which can be
    // slow and may prompt for user auth depending on accessibility flags) on
    // every Signal Protocol operation.
    if (_cachedIdentityKeyPair != null &&
        _cachedRegistrationId != null &&
        _cachedUserId != null) {
      return SpectreIdentity(
        identityKeyPair: _cachedIdentityKeyPair!,
        registrationId: _cachedRegistrationId!,
        userId: _cachedUserId!,
      );
    }

    final existingIdkp = await _storage.read(key: _kIdentityKeyPair);
    final existingReg = await _storage.read(key: _kRegistrationId);
    final existingUid = await _storage.read(key: _kUserId);

    if (existingIdkp != null && existingReg != null && existingUid != null) {
      // All three pieces must be present together. If any one is missing we
      // treat the install as corrupted and regenerate, because a partial
      // identity would silently break sessions in confusing ways.
      final idkp = IdentityKeyPair.fromSerialized(base64Decode(existingIdkp));
      final regId = int.parse(existingReg);

      _cachedIdentityKeyPair = idkp;
      _cachedRegistrationId = regId;
      _cachedUserId = existingUid;

      return SpectreIdentity(
        identityKeyPair: idkp,
        registrationId: regId,
        userId: existingUid,
      );
    }

    // First-run (or recovered-from-partial) path: generate everything fresh.
    return _generateAndPersist();
  }

  Future<SpectreIdentity> _generateAndPersist() async {
    // Curve25519 key pair used as the device's identity. libsignal handles
    // the actual key generation using a CSPRNG.
    final identityKeyPair = KeyHelper.generateIdentityKeyPair();

    // Per Signal spec, the registrationId is a 14-bit value (1..16380).
    // `false` here means non-extended range, which is what the wire protocol
    // expects.
    final registrationId = KeyHelper.generateRegistrationId(false);

    // User ID: 256 bits from the platform CSPRNG, base64url encoded
    // (no padding) so it's URL/QR safe for out-of-band exchange. We
    // deliberately use 32 bytes (~43 chars) rather than a UUIDv4 (~122 bits)
    // because the user ID *is* the addressable handle on the relay — we want
    // enough entropy that it is unguessable and collision-free across a
    // global user base.
    final userId = _generateUserId();

    // Persist atomically-ish. flutter_secure_storage doesn't expose a real
    // transaction, so we write identity material first, then the user ID
    // last. On a crash between writes loadOrCreate() will see a partial
    // state and regenerate — better than handing out a userId that has no
    // identity behind it.
    await _storage.write(
      key: _kIdentityKeyPair,
      value: base64Encode(identityKeyPair.serialize()),
    );
    await _storage.write(
      key: _kRegistrationId,
      value: registrationId.toString(),
    );
    await _storage.write(key: _kUserId, value: userId);

    _cachedIdentityKeyPair = identityKeyPair;
    _cachedRegistrationId = registrationId;
    _cachedUserId = userId;

    return SpectreIdentity(
      identityKeyPair: identityKeyPair,
      registrationId: registrationId,
      userId: userId,
    );
  }

  /// Panic wipe. Deletes all identity material from secure storage and clears
  /// in-memory caches. After this call the next [loadOrCreate] will produce
  /// a completely new identity with no cryptographic link to the old one.
  ///
  /// Note: this only wipes identity. Session state, prekeys, and the
  /// encrypted message database live elsewhere and must be wiped by their
  /// respective managers as part of a full panic flow.
  Future<void> wipeIdentity() async {
    // Delete keys individually rather than calling deleteAll(), so that any
    // unrelated keys another component happens to store under the same
    // namespace are not collateral damage. If you want a true scorched-earth
    // wipe, the caller should orchestrate it across all managers.
    await _storage.delete(key: _kIdentityKeyPair);
    await _storage.delete(key: _kRegistrationId);
    await _storage.delete(key: _kUserId);
    await _storage.delete(key: _kDisplayName);
    await _storage.delete(key: 'spectre.sealed_ca_pub');

    // Zero out in-memory references. Dart strings are immutable so we can't
    // actually scrub the bytes — the best we can do is drop references and
    // hope the GC reclaims them before a memory dump. For real forward
    // secrecy against memory forensics, the process should be killed
    // immediately after a panic wipe.
    _cachedIdentityKeyPair = null;
    _cachedRegistrationId = null;
    _cachedUserId = null;
    _cachedDisplayName = null;
    _displayNameLoaded = false;
  }

  static String _generateUserId() {
    // Random.secure() is backed by the platform CSPRNG (/dev/urandom on
    // Linux/Android, SecRandomCopyBytes on iOS). Throws if no secure source
    // is available, which is the right failure mode — we'd rather crash than
    // hand out a predictable ID.
    final rng = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = rng.nextInt(256);
    }
    // base64url without padding: filesystem-, URL-, and QR-code-safe.
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

/// Immutable snapshot of this device's Signal identity. Pass by value to
/// other crypto components; do not let it escape outside the crypto layer.
class SpectreIdentity {
  final IdentityKeyPair identityKeyPair;
  final int registrationId;
  final String userId;

  const SpectreIdentity({
    required this.identityKeyPair,
    required this.registrationId,
    required this.userId,
  });
}
