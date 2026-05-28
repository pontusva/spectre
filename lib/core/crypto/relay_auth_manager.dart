import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Manages an Ed25519 keypair used SOLELY to authenticate to the Spectre
/// relay. This is intentionally separate from the libsignal IdentityKeyPair.
///
/// Why a dedicated relay-auth key rather than reusing the Signal identity:
///   * libsignal_protocol_dart's identity is a Curve25519 key, and its
///     `Curve.calculateSignature` produces an XEdDSA signature — an
///     ed25519-compatible signature derived from a Curve25519 private
///     key via implicit Edwards conversion. The Go relay verifies plain
///     ed25519 with golang.org/x/crypto, which does NOT implement XEdDSA.
///     Bridging the two would require shipping an edwards25519 conversion
///     routine on the server (added attack surface) or in pure Dart here
///     (added attack surface, and a hand-rolled crypto path is exactly
///     what we don't want under this threat model).
///   * Domain separation. Compromising the relay-auth key lets an attacker
///     impersonate this device to the relay; it does NOT let them
///     impersonate the device in Signal sessions. The two trust anchors
///     are kept independent on purpose. Defense in depth.
///   * If the relay-auth key is ever rotated (e.g. on a new relay onboard
///     flow), the Signal identity and existing E2E sessions are untouched.
///
/// Why ed25519_edwards rather than package:cryptography:
///   The relay verifies signatures with Go's `ed25519.Verify(pub, msg, sig)`,
///   which is pure RFC 8032 Ed25519 over the raw message bytes — no
///   prehashing. We need the client's signing path to match exactly.
///   ed25519_edwards is a straight Dart port of `golang.org/x/crypto/ed25519`
///   (see its package comment) so a signature produced here is byte-for-byte
///   identical to what the relay would produce for the same key+message.
///   package:cryptography's high-level `Ed25519` does not expose an opt-out
///   for prehashing variants, so a future internal change there could
///   silently break relay auth — not a risk worth taking on the auth path.
class RelayAuthManager {
  // Storage keys are the exact strings specified by the relay-auth contract.
  // They are short and opaque so a keystore namespace dump doesn't
  // immediately reveal what the values are for.
  static const String _kPubKey = 'spectre_relay_auth_pub';
  static const String _kPrivKey = 'spectre_relay_auth_priv';

  // ed25519 raw public key length (RFC 8032 PublicKeySize).
  static const int _kPubKeyLen = 32;
  // ed25519_edwards' PrivateKey is the RFC 8032 `seed || public` form,
  // 64 bytes total — matching Go's `ed25519.PrivateKey`. We persist the
  // same blob the library hands us so loading is just a constructor call,
  // not a derivation step.
  static const int _kPrivKeyLen = 64;

  final FlutterSecureStorage _storage;

  ed.PrivateKey? _cachedPriv;
  ed.PublicKey? _cachedPub;

  RelayAuthManager({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // Match the IdentityManager's storage options so both keys
              // live behind the Android Keystore / iOS Keychain with the
              // same accessibility constraints. Diverging here would
              // create a subtle window where one credential is available
              // after first unlock and the other isn't.
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
                resetOnError: false,
              ),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
                synchronizable: false,
              ),
            );

  /// Returns the base64-encoded raw 32-byte ed25519 public key.
  /// The relay receives this verbatim in the auth request's
  /// `identity_public_key` field and verifies signatures against it.
  Future<String> publicKeyBase64() async {
    await loadOrCreate();
    return base64Encode(_cachedPub!.bytes);
  }

  /// Signs the relay-issued nonce with the device's relay-auth private key.
  /// Returns the raw 64-byte ed25519 signature.
  ///
  /// Pure RFC 8032 Ed25519 — the nonce bytes are fed into the signing
  /// algorithm directly, no prehashing, no domain separator. This is
  /// exactly the wire format Go's `ed25519.Verify` expects on the relay.
  ///
  /// The caller (RelayService) is responsible for base64-encoding the
  /// returned bytes before placing them on the wire.
  Future<Uint8List> sign(Uint8List nonce) async {
    await loadOrCreate();
    final sig = ed.sign(_cachedPriv!, nonce);
    // Defensive copy: ed25519_edwards already returns a fresh Uint8List,
    // but wrapping again is cheap and insulates callers from any future
    // change in the library's return-value contract.
    return Uint8List.fromList(sig);
  }

  /// Panic-wipe hook. Deletes the persisted keypair and clears in-memory
  /// caches. After this call the relay-auth identity is unrecoverable; the
  /// next `sign` will provision a fresh keypair that the relay has never
  /// seen and will (correctly) reject until re-pairing.
  ///
  /// Note: this only wipes relay-auth material. Signal identity, sessions,
  /// prekeys, and the message DB are wiped by their own managers as part
  /// of the larger panic flow.
  Future<void> wipeRelayAuth() async {
    // Delete keys individually rather than clobbering the whole namespace,
    // to avoid collateral damage on other components' storage.
    await _storage.delete(key: _kPubKey);
    await _storage.delete(key: _kPrivKey);

    // Drop references. Dart can't zero memory deterministically — for true
    // forward secrecy against a memory dump, the process should exit
    // immediately after panic wipe completes across all managers.
    _cachedPriv = null;
    _cachedPub = null;
  }

  /// Lazy-initializes the in-memory keypair from storage, generating a
  /// new one on first run. Idempotent. Exposed so the app-boot pipeline
  /// can pre-warm storage before the first relay handshake, ensuring a
  /// keystore write isn't racing the auth latency budget.
  Future<void> loadOrCreate() async {
    if (_cachedPriv != null && _cachedPub != null) return;

    final String? pubB64 = await _storage.read(key: _kPubKey);
    final String? privB64 = await _storage.read(key: _kPrivKey);

    if (pubB64 != null && privB64 != null) {
      final Uint8List pub = base64Decode(pubB64);
      final Uint8List priv = base64Decode(privB64);
      // Strict length validation. Anything else is corruption or tampering —
      // we refuse to load and regenerate instead of silently truncating.
      if (pub.length == _kPubKeyLen && priv.length == _kPrivKeyLen) {
        // Cross-check the trailing 32 bytes of priv against the pub slot.
        // A mismatch means one of the two storage entries was replaced
        // independently of the other; the safe response is to discard and
        // regenerate rather than sign under a key the relay doesn't know.
        var matches = true;
        for (var i = 0; i < _kPubKeyLen; i++) {
          if (pub[i] != priv[_kPubKeyLen + i]) {
            matches = false;
            break;
          }
        }
        if (matches) {
          _cachedPriv = ed.PrivateKey(priv);
          _cachedPub = ed.PublicKey(pub);
          return;
        }
      }
    }

    // First run, or recovery from partial/corrupted storage.
    //
    // `ed.generateKey()` seeds from `Random.secure()` internally (which
    // on Android/Linux is /dev/urandom and on iOS is SecRandomCopyBytes).
    // We do not roll our own RNG here.
    final ed.KeyPair keyPair = ed.generateKey();
    // ed25519_edwards types KeyPair fields as nullable, but `generateKey()`
    // always populates both — null here would be a library bug.
    final ed.PrivateKey priv = keyPair.privateKey!;
    final ed.PublicKey pub = keyPair.publicKey!;

    // Persist BEFORE caching: if writes fail we want the next call to
    // attempt a regeneration rather than hand out an ephemeral keypair
    // that the relay has never been told about.
    await _storage.write(
        key: _kPrivKey, value: base64Encode(priv.bytes));
    await _storage.write(
        key: _kPubKey, value: base64Encode(pub.bytes));

    _cachedPriv = priv;
    _cachedPub = pub;
  }
}
