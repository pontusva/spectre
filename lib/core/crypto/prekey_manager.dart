import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'identity_manager.dart';

/// Manages one-time PreKeys and the SignedPreKey for X3DH session
/// establishment.
///
/// Why prekeys exist (forward-secrecy primer):
///   * Signal's X3DH handshake combines the sender's identity key, the
///     recipient's identity key, the recipient's SignedPreKey, and ideally
///     a one-time PreKey to derive the initial session root key.
///   * The one-time PreKey is, as the name suggests, used exactly once and
///     then DESTROYED. This is the leg of the handshake that gives the
///     initial message forward secrecy: even if the recipient's long-term
///     identity key is later compromised, an attacker who recorded the
///     ciphertext cannot recover the one-time prekey's private half (it
///     no longer exists on any device), so they cannot re-derive the
///     session key.
///   * If the server runs out of one-time prekeys for a recipient, X3DH
///     degrades to using only the SignedPreKey. Sessions established this
///     way are still authentic, but they lose the per-session forward
///     secrecy guarantee until the first Double-Ratchet message is sent.
///     That is why we refill aggressively (threshold of 20 below).
///   * The SignedPreKey provides a medium-term ECDH contribution that is
///     authenticated by the long-term identity key. Rotating it weekly
///     bounds the window during which a compromise of the SignedPreKey's
///     private half can be used to break new incoming session setups. The
///     identity key itself is never rotated (doing so would invalidate
///     every safety-number verification the user has ever done), so the
///     SignedPreKey rotation is the mechanism that gives us "medium-term"
///     forward secrecy.
class PreKeyManager {
  // How many one-time prekeys to keep available at any time. Signal's own
  // clients use 100 as the default batch size; the server can serve one to
  // each peer that wants to start a session with us, so this comfortably
  // covers a week's worth of new conversations for most users.
  static const int kInitialPreKeyCount = 100;

  // When the local supply drops below this threshold we generate another
  // batch. We refill *before* exhaustion so there is always overlap — a
  // peer that fetches a bundle from the server during the refill window
  // gets a real one-time prekey, not the no-prekey fallback.
  static const int kRefillThreshold = 20;
  static const int kRefillBatchSize = 100;

  // SignedPreKeys are rotated on a 7-day cadence per Signal's spec. We keep
  // the previous SignedPreKey around for one extra rotation period so that
  // in-flight session-init messages signed against the previous key can
  // still be decrypted; after that they are discarded.
  static const Duration kSignedPreKeyRotationInterval = Duration(days: 7);

  // Storage key namespacing. Each prekey record is stored under its own
  // key so we can read/delete them individually without rewriting a giant
  // blob on every consumption.
  static const _kPreKeyIndex = 'spectre.pk.index';
  static const _kPreKeyNextId = 'spectre.pk.next';
  static const _kPreKeyPrefix = 'spectre.pk.';
  static const _kSignedPreKeyCurId = 'spectre.spk.cur';
  static const _kSignedPreKeyPrevId = 'spectre.spk.prev';
  static const _kSignedPreKeyNextId = 'spectre.spk.next';
  static const _kSignedPreKeyPrefix = 'spectre.spk.';
  static const _kSignedPreKeyRotatedAt = 'spectre.spk.rotated';

  final FlutterSecureStorage _storage;
  final IdentityManager _identityManager;

  PreKeyManager({
    required this._identityManager,
    FlutterSecureStorage? storage,
  })  : _storage = storage ??
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

  /// Loads existing prekeys from storage or generates the initial batch on
  /// first run. Call once at startup, before any session is established.
  Future<void> loadOrCreate() async {
    final indexRaw = await _storage.read(key: _kPreKeyIndex);
    final signedCurRaw = await _storage.read(key: _kSignedPreKeyCurId);

    if (indexRaw != null && signedCurRaw != null) {
      // Existing install. Nothing to do — records are loaded lazily on use.
      return;
    }

    await _generateInitialBatch();
  }

  Future<void> _generateInitialBatch() async {
    final identity = await _identityManager.loadOrCreate();

    // PreKey IDs are 24-bit unsigned ints per the spec. We start at 1
    // (0 is reserved as "no prekey") and persist a monotonically increasing
    // counter so that IDs are never reused even after consumption — reusing
    // an ID would let an attacker who recorded an old PreKeyMessage replay
    // it against a freshly generated prekey with the same ID.
    final preKeys = KeyHelper.generatePreKeys(1, kInitialPreKeyCount);
    await _persistPreKeys(preKeys);
    await _storage.write(
      key: _kPreKeyNextId,
      value: (kInitialPreKeyCount + 1).toString(),
    );
    await _storage.write(
      key: _kPreKeyIndex,
      value: jsonEncode(preKeys.map((p) => p.id).toList()),
    );

    // SignedPreKey IDs share the 24-bit space but live in a separate
    // counter — they are stored and looked up independently.
    final signedPreKey =
        KeyHelper.generateSignedPreKey(identity.identityKeyPair, 1);
    await _persistSignedPreKey(signedPreKey);
    await _storage.write(key: _kSignedPreKeyCurId, value: '1');
    await _storage.write(key: _kSignedPreKeyNextId, value: '2');
    await _storage.write(
      key: _kSignedPreKeyRotatedAt,
      value: DateTime.now().toUtc().millisecondsSinceEpoch.toString(),
    );
  }

  /// Returns every currently-available one-time PreKey. Use this to upload
  /// the initial PreKey bundle to the relay server.
  Future<List<PreKeyRecord>> getAllPreKeys() async {
    final ids = await _readPreKeyIndex();
    final out = <PreKeyRecord>[];
    for (final id in ids) {
      final rec = await _readPreKey(id);
      if (rec != null) out.add(rec);
    }
    return out;
  }

  /// Returns the currently active SignedPreKey, used to build the public
  /// prekey bundle and to respond to incoming session-init messages.
  Future<SignedPreKeyRecord> getCurrentSignedPreKey() async {
    final id = int.parse((await _storage.read(key: _kSignedPreKeyCurId))!);
    return (await _readSignedPreKey(id))!;
  }

  /// Returns the previous SignedPreKey if one is being held during the
  /// rotation grace window, otherwise null. The session-decrypt path needs
  /// to try this when an incoming PreKeyMessage references an ID we have
  /// already rotated away from.
  Future<SignedPreKeyRecord?> getPreviousSignedPreKey() async {
    final prevIdRaw = await _storage.read(key: _kSignedPreKeyPrevId);
    if (prevIdRaw == null) return null;
    return _readSignedPreKey(int.parse(prevIdRaw));
  }

  /// Removes a one-time prekey that has just been consumed by an incoming
  /// PreKeyMessage. This is what actually delivers initial-message forward
  /// secrecy: after this call returns, no copy of the private half exists
  /// on this device. Triggers an asynchronous refill if supply is low.
  Future<PreKeyRecord?> consumePreKey(int preKeyId) async {
    final record = await _readPreKey(preKeyId);
    if (record == null) {
      // Either the prekey was never ours or it has already been consumed.
      // Returning null lets the caller fall back to a no-onetime-prekey
      // session setup rather than crashing.
      return null;
    }

    await _storage.delete(key: '$_kPreKeyPrefix$preKeyId');
    final ids = await _readPreKeyIndex();
    ids.remove(preKeyId);
    await _storage.write(key: _kPreKeyIndex, value: jsonEncode(ids));

    if (ids.length < kRefillThreshold) {
      // Refill inline. We could schedule this off the critical path, but
      // running out of one-time prekeys is a forward-secrecy degradation,
      // so we'd rather pay the latency now than risk the next incoming
      // session setup falling back to SignedPreKey-only X3DH.
      await _refillPreKeys();
    }

    return record;
  }

  Future<void> _refillPreKeys() async {
    final nextId = int.parse((await _storage.read(key: _kPreKeyNextId))!);
    final fresh = KeyHelper.generatePreKeys(nextId, kRefillBatchSize);
    await _persistPreKeys(fresh);

    final ids = await _readPreKeyIndex();
    ids.addAll(fresh.map((p) => p.id));
    await _storage.write(key: _kPreKeyIndex, value: jsonEncode(ids));
    await _storage.write(
      key: _kPreKeyNextId,
      value: (nextId + kRefillBatchSize).toString(),
    );
    // NB: callers are responsible for uploading the new prekeys to the
    // relay so peers can fetch them. We don't do network I/O from this
    // layer — keeping the crypto pure and side-effect-free makes it much
    // easier to audit.
  }

  /// Rotates the SignedPreKey. Should be called approximately weekly; the
  /// caller is responsible for scheduling (e.g. a periodic WorkManager job
  /// on Android, BGTaskScheduler on iOS).
  ///
  /// Rotation flow:
  ///   1. Promote current -> previous (kept for one rotation period so
  ///      in-flight session-init messages signed against it can still
  ///      establish sessions).
  ///   2. Generate and persist a new current SignedPreKey, signed by the
  ///      long-term identity key.
  ///   3. Delete any older "previous" record beyond the grace window.
  ///
  /// Skipping a rotation is non-fatal — the worst case is that the
  /// medium-term forward-secrecy window widens — but rotations must never
  /// happen MORE often than the upload cadence to the relay, or peers will
  /// fetch a SignedPreKey we've already discarded.
  Future<SignedPreKeyRecord> rotateSignedPreKey() async {
    final identity = await _identityManager.loadOrCreate();

    final curIdRaw = await _storage.read(key: _kSignedPreKeyCurId);
    final prevIdRaw = await _storage.read(key: _kSignedPreKeyPrevId);
    final nextIdRaw = await _storage.read(key: _kSignedPreKeyNextId);

    // Drop the existing "previous" record — it's now two rotations old
    // and any session that was going to use it has long since started.
    if (prevIdRaw != null) {
      await _storage.delete(key: '$_kSignedPreKeyPrefix$prevIdRaw');
    }

    // Promote current to previous (keep the bytes; just relabel).
    if (curIdRaw != null) {
      await _storage.write(key: _kSignedPreKeyPrevId, value: curIdRaw);
    }

    final newId = int.parse(nextIdRaw ?? '1');
    final newRecord =
        KeyHelper.generateSignedPreKey(identity.identityKeyPair, newId);
    await _persistSignedPreKey(newRecord);

    await _storage.write(key: _kSignedPreKeyCurId, value: newId.toString());
    await _storage.write(
      key: _kSignedPreKeyNextId,
      value: (newId + 1).toString(),
    );
    await _storage.write(
      key: _kSignedPreKeyRotatedAt,
      value: DateTime.now().toUtc().millisecondsSinceEpoch.toString(),
    );

    return newRecord;
  }

  /// Returns the timestamp at which the current SignedPreKey was minted,
  /// or `null` if no SignedPreKey has been generated yet (i.e. before
  /// first run). Used by the settings UI to display the rotation date.
  Future<DateTime?> lastSignedPreKeyRotation() async {
    final ts = await _storage.read(key: _kSignedPreKeyRotatedAt);
    if (ts == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(int.parse(ts), isUtc: true);
  }

  /// Returns true if the SignedPreKey is older than the rotation interval.
  /// The scheduler should call this on each app launch / periodic wake-up
  /// to decide whether to invoke [rotateSignedPreKey].
  Future<bool> isSignedPreKeyStale() async {
    final ts = await _storage.read(key: _kSignedPreKeyRotatedAt);
    if (ts == null) return true;
    final rotatedAt =
        DateTime.fromMillisecondsSinceEpoch(int.parse(ts), isUtc: true);
    return DateTime.now().toUtc().difference(rotatedAt) >=
        kSignedPreKeyRotationInterval;
  }

  /// Wipes every prekey and signed-prekey record. Part of the panic-wipe
  /// flow — call alongside [IdentityManager.wipeIdentity].
  Future<void> wipeAll() async {
    // Using deleteAll() is a scorched-earth operation that clears all keys from
    // secure storage in a single fast call. This prevents executing 100+ separate
    // delete operations sequentially, which blocks the UI thread and causes
    // macOS/iOS Keychain connection timeouts.
    await _storage.deleteAll();
  }

  // ---------------------------------------------------------------------
  // Storage helpers. Records are base64-encoded so they survive the
  // string-only flutter_secure_storage API on every platform.
  // ---------------------------------------------------------------------

  Future<List<int>> _readPreKeyIndex() async {
    final raw = await _storage.read(key: _kPreKeyIndex);
    if (raw == null) return <int>[];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded.cast<int>();
  }

  Future<PreKeyRecord?> _readPreKey(int id) async {
    final raw = await _storage.read(key: '$_kPreKeyPrefix$id');
    if (raw == null) return null;
    return PreKeyRecord.fromBuffer(base64Decode(raw));
  }

  Future<void> _persistPreKeys(List<PreKeyRecord> records) async {
    for (final r in records) {
      await _storage.write(
        key: '$_kPreKeyPrefix${r.id}',
        value: base64Encode(r.serialize()),
      );
    }
  }

  Future<SignedPreKeyRecord?> _readSignedPreKey(int id) async {
    final raw = await _storage.read(key: '$_kSignedPreKeyPrefix$id');
    if (raw == null) return null;
    return SignedPreKeyRecord.fromSerialized(base64Decode(raw));
  }

  Future<void> _persistSignedPreKey(SignedPreKeyRecord record) async {
    await _storage.write(
      key: '$_kSignedPreKeyPrefix${record.id}',
      value: base64Encode(record.serialize()),
    );
  }
}
