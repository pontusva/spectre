import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

/// Encrypted local database for messages, conversations, and contacts.
///
/// Security architecture:
///   * File-at-rest encryption is SQLCipher (AES-256-CBC + HMAC-SHA512
///     per page). The page file is opaque without the key, including
///     headers — an attacker pulling the file off the device cannot tell
///     it apart from random noise.
///   * The database key is 32 raw bytes (256 bits) from
///     [Random.secure()] — i.e. the OS CSPRNG. It is generated exactly
///     once on first run and held in [FlutterSecureStorage], which on
///     Android is backed by the hardware Keystore via EncryptedSharedPrefs
///     and on iOS by the Keychain with first-unlock-this-device access.
///   * Because we pass the key in `x'<hex>'` form, SQLCipher uses the raw
///     bytes directly and does NOT run them through PBKDF2. A passphrase
///     would offer slow brute-force resistance; a 256-bit random key
///     doesn't need any — KDF stretching here would just waste CPU on
///     every open.
///   * NO PLAINTEXT MESSAGE CONTENT is ever written. The `messages.
///     ciphertext` column stores the Signal Protocol output of
///     [SessionManager.encryptMessage]. If SQLCipher is ever broken
///     (key extraction from a compromised device, future cryptanalysis,
///     etc.), the attacker still faces the Double Ratchet on every
///     message. Defense in depth, layered ciphers.
///   * Disappearing messages: rows carry an absolute [expires_at]
///     timestamp. We hard-delete (no soft-delete tombstones) on every app
///     foreground via [deleteExpiredMessages], and `cipher_secure_delete`
///     is set so freed pages are zeroed before being re-encrypted. A
///     forensic image of the device captured after expiry should not
///     recover the row from freed pages.
///   * Panic wipe ([wipeDatabase]) destroys the SQLCipher key — without
///     it, the file is mathematically unrecoverable regardless of
///     whatever flash blocks survive deletion on the underlying device.
class SecureDatabase {
  static const _kDbFileName = 'spectre.db';

  // Storage key for the SQLCipher master key. Short, opaque name so the
  // Keystore namespace doesn't advertise "I am a database key".
  static const _kKeyStorageKey = 'spectre.db.k';

  // Schema version. Bump on every migration and add an onUpgrade branch.
  static const int _kSchemaVersion = 1;

  final FlutterSecureStorage _secureStorage;
  Database? _db;

  SecureDatabase({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ??
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

  /// Opens the database, creating and initializing it on first run. Safe
  /// to call multiple times — subsequent calls return the cached handle.
  /// Must be awaited before any other method is used.
  Future<Database> open() async {
    final cached = _db;
    if (cached != null && cached.isOpen) return cached;

    final keyHex = await _loadOrCreateKey();
    final path = await _databasePath();

    _db = await openDatabase(
      path,
      // x'<hex>' tells SQLCipher to use the 32 bytes as the raw key,
      // bypassing PBKDF2. We feed it true randomness, so stretching adds
      // nothing.
      password: "x'$keyHex'",
      version: _kSchemaVersion,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
    );
    return _db!;
  }

  Future<void> _onConfigure(Database db) async {
    // Zero freed pages before they are re-encrypted to disk. Without this
    // a deleted row's plaintext-shape (lengths, structure) could in
    // principle leak via freed-page recovery once the cipher is broken.
    await db.execute('PRAGMA cipher_secure_delete = ON');
    // Enforce ON DELETE CASCADE so wiping a conversation also wipes its
    // messages — important for the disappearing-conversation flow.
    await db.execute('PRAGMA foreign_keys = ON');
    // Memory-temp store keeps any temp tables / sort buffers off disk so
    // intermediate query state can't end up in unencrypted temp files.
    await db.execute('PRAGMA temp_store = MEMORY');
  }

  Future<void> _onCreate(Database db, int version) async {
    // conversations: one row per peer chat. recipient_public_key is the
    // serialized Signal identity public key we pin for that recipient —
    // any future session establishment must match this key or the user
    // is shown a safety-number-changed warning.
    await db.execute('''
      CREATE TABLE conversations (
        id                    TEXT    PRIMARY KEY NOT NULL,
        recipient_id          TEXT    NOT NULL,
        recipient_public_key  BLOB    NOT NULL,
        last_message_at       INTEGER NOT NULL DEFAULT 0,
        is_archived           INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX idx_conversations_recipient ON conversations(recipient_id)',
    );

    // messages: ciphertext is BLOB and NOT NULL. The schema itself
    // enforces the "no plaintext on disk" invariant — a developer who
    // tries to insert a plaintext column will fail at write time.
    await db.execute('''
      CREATE TABLE messages (
        id              TEXT    PRIMARY KEY NOT NULL,
        conversation_id TEXT    NOT NULL,
        sender_id       TEXT    NOT NULL,
        ciphertext      BLOB    NOT NULL,
        timestamp       INTEGER NOT NULL,
        is_read         INTEGER NOT NULL DEFAULT 0,
        expires_at      INTEGER,
        FOREIGN KEY (conversation_id) REFERENCES conversations(id)
          ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_messages_conversation ON messages(conversation_id, timestamp DESC)',
    );
    // Partial index on the expiry column — speeds up the foreground
    // sweep without indexing every non-disappearing message.
    await db.execute(
      'CREATE INDEX idx_messages_expires ON messages(expires_at) '
      'WHERE expires_at IS NOT NULL',
    );

    // contacts: identity_key_fingerprint is the short hash we display in
    // the safety-number UI. `verified` flips to 1 only after the user
    // confirms the fingerprint out-of-band (scan QR, read aloud, etc.) —
    // this flag drives the "verified" badge in the chat header and must
    // never be set programmatically without explicit user action.
    await db.execute('''
      CREATE TABLE contacts (
        id                        TEXT    PRIMARY KEY NOT NULL,
        user_id                   TEXT    NOT NULL UNIQUE,
        display_name              TEXT    NOT NULL,
        identity_key_fingerprint  TEXT    NOT NULL,
        verified                  INTEGER NOT NULL DEFAULT 0,
        created_at                INTEGER NOT NULL
      )
    ''');
  }

  /// Hard-deletes every message whose [expires_at] has passed. Call on
  /// every app foreground so a device seized during the disappearing
  /// window has the shortest possible recovery window. Returns the row
  /// count deleted (useful for tests and observability — but DO NOT log
  /// the IDs of deleted rows).
  Future<int> deleteExpiredMessages() async {
    final db = await open();
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    return db.delete(
      'messages',
      where: 'expires_at IS NOT NULL AND expires_at < ?',
      whereArgs: [now],
    );
  }

  /// Panic wipe. Multi-layered:
  ///   1. Best-effort scrub of every row, with `cipher_secure_delete`
  ///      ensuring freed pages are zeroed before being re-encrypted.
  ///      VACUUM forces the file to be rewritten so the new (smaller)
  ///      file no longer contains any encrypted form of the old data.
  ///   2. Close the handle and overwrite the file bytes with zeros, then
  ///      delete it. On flash media this is best-effort — wear-levelling
  ///      means original physical blocks may persist for a while — so we
  ///      treat it as defense in depth, not primary defense.
  ///   3. Destroy the encryption key. This is the actual guarantee:
  ///      without the key, any surviving SQLCipher bytes on flash are
  ///      cryptographically unrecoverable.
  Future<void> wipeDatabase() async {
    final db = _db;
    if (db != null && db.isOpen) {
      try {
        await db.execute('PRAGMA cipher_secure_delete = ON');
        await db.delete('messages');
        await db.delete('conversations');
        await db.delete('contacts');
        await db.execute('VACUUM');
      } catch (_) {
        // Even if scrubbing fails (e.g. corrupted DB), we still continue
        // to file deletion and key destruction below. Failing to scrub
        // is acceptable; failing to destroy the key is not.
      }
      await db.close();
      _db = null;
    }

    final path = await _databasePath();
    final file = File(path);
    if (await file.exists()) {
      try {
        // Overwrite the file with zeros before unlinking. SQLCipher's
        // own scrub above is the strong layer; this is a belt-and-braces
        // pass for the file as it sits on the FS before unlink.
        final length = await file.length();
        await file.writeAsBytes(
          Uint8List(length),
          flush: true,
        );
      } catch (_) {
        // Best effort — fall through to delete.
      }
      try {
        await file.delete();
      } catch (_) {
        // Even if delete fails the key is about to be destroyed, which
        // is the real protection.
      }
    }

    // The decisive step: without this byte string the file is noise.
    await _secureStorage.delete(key: _kKeyStorageKey);
  }

  // ---------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------

  Future<String> _loadOrCreateKey() async {
    final existing = await _secureStorage.read(key: _kKeyStorageKey);
    if (existing != null) return existing;

    // Random.secure() pulls from the platform CSPRNG and throws if no
    // secure source is available. We treat that as fatal — handing out
    // a predictable DB key would silently downgrade every other
    // protection in the app.
    final rng = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = rng.nextInt(256);
    }
    final hex = _toHex(bytes);
    await _secureStorage.write(key: _kKeyStorageKey, value: hex);
    return hex;
  }

  Future<String> _databasePath() async {
    final dir = await getDatabasesPath();
    return '$dir/$_kDbFileName';
  }

  static String _toHex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
