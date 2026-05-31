import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/contact.dart';
import '../models/conversation.dart';
import '../models/message.dart';

part 'secure_database.g.dart';

// ---------------------------------------------------------------------------
// Table definitions.
//
// Each row class is named *Row to avoid clashing with the higher-level
// model types (Message, Conversation, Contact) defined under core/models.
// Conversion between the two layers happens in the public methods below.
// ---------------------------------------------------------------------------

@DataClassName('MessageRow')
class Messages extends Table {
  // Caller-generated UUID. The database NEVER mints IDs itself, so a row
  // exported and re-imported keeps the same identity. This also makes the
  // PRIMARY KEY usable for the recipient-side dedup hash in MessageService.
  TextColumn get id => text()();

  // FK to conversations.id with ON DELETE CASCADE — deleting a peer's
  // conversation removes all of their messages atomically. Important for
  // the "delete contact" flow which needs predictable cascading.
  TextColumn get conversationId =>
      text().references(Conversations, #id, onDelete: KeyAction.cascade)();

  TextColumn get senderId => text()();

  // The Signal ciphertext envelope (SessionManager.encryptMessage output).
  // Retained for the content-hash message id / replay dedup; it can never be
  // re-decrypted (the Double Ratchet is one-time), so it is NOT what renders
  // history.
  BlobColumn get ciphertext => blob()();

  // DELIBERATE POSTURE DECISION (see also Message model + SPECTRE_DEVLOG
  // Principle #2): readable message history requires storing the plaintext,
  // because the ratchet ciphertext above is unrecoverable. This column holds
  // it, encrypted AT REST by SQLCipher (key in the OS keystore) — the same
  // posture as Signal. Nullable: inbound messages that never decrypted, and
  // legacy rows, have null. Panic-wipe (key destruction) and the
  // disappearing-message sweep both purge it by removing the row. A seized,
  // UNLOCKED device can read it — that is the accepted cost of usable history;
  // panic-wipe is the mitigation.
  TextColumn get plaintext => text().nullable()();

  // Stored as Unix milliseconds. We don't use drift's dateTime() type so
  // that wire-format compatibility with the previous sqflite schema is
  // preserved and so that timestamps survive timezone migration.
  IntColumn get timestamp => integer()();
  BoolColumn get isRead =>
      boolean().withDefault(const Constant(false))();

  // Nullable — absent means the message does not auto-expire. An absolute
  // expiry instant (not a duration) so that a device clock rewound
  // backwards cannot delay deletion.
  IntColumn get expiresAt => integer().nullable()();

  BoolColumn get isMine =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ConversationRow')
class Conversations extends Table {
  TextColumn get id => text()();

  // UNIQUE: one conversation row per peer. Trying to insert a duplicate
  // is a programmer error (use insertOnConflictUpdate to refresh).
  TextColumn get recipientId =>
      text().customConstraint('NOT NULL UNIQUE')();

  // The peer's serialized Signal identity public key. Pinned at first
  // contact — silently re-negotiating with a different key is the classic
  // MITM vector. The UI compares this against any future bundle and shows
  // a safety-number warning on mismatch.
  BlobColumn get recipientPublicKey => blob()();

  IntColumn get lastMessageAt => integer().nullable()();
  BoolColumn get isArchived =>
      boolean().withDefault(const Constant(false))();
  IntColumn get unreadCount =>
      integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ContactRow')
class Contacts extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text().customConstraint('NOT NULL UNIQUE')();
  TextColumn get displayName => text().nullable()();
  TextColumn get identityKeyFingerprint => text()();

  // Only flipped after explicit out-of-band confirmation by the user. No
  // programmatic auto-verify path exists anywhere in the codebase.
  BoolColumn get isVerified =>
      boolean().withDefault(const Constant(false))();

  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// Database.
//
// Why this stack:
//   * drift gives us typed queries that survive schema changes. Queries
//     run on the main isolate (see ISOLATE NOTE below).
//   * Encryption is SQLCipher applied via PRAGMA key on the underlying
//     sqlite3 connection. The same Dart source compiles and runs on
//     every drift-supported platform because the SQLCipher binary is
//     provided by the host environment.
//   * Key material lives in [FlutterSecureStorage], hardware-backed via
//     Android Keystore / iOS Keychain. The DB file is opaque without it.
//   * Passing the key as `PRAGMA key = "x'<hex>'"` makes SQLCipher use
//     the raw 256 bits directly, bypassing PBKDF2 — a passphrase KDF is
//     pointless when the input already has 256 bits of CSPRNG entropy.
//
// ISOLATE NOTE — we use NativeDatabase (same-isolate) rather than
// NativeDatabase.createInBackground. The background-isolate path
// requires the `setup` closure to be sendable across isolate
// boundaries, which fails when the closure captures plugin-backed
// objects such as FlutterSecureStorage (the unsendable
// _AsyncCompleter from the plugin's MethodChannel surfaces as an
// "object is unsendable" error at runtime). We sacrifice the
// background-isolate performance optimization here for correctness.
// This can be revisited later by extracting the setup into a
// top-level (non-closure) function that reads the key from a
// pre-resolved string parameter, allowing the isolate to receive
// only sendable values.
// ---------------------------------------------------------------------------

@DriftDatabase(tables: [Messages, Conversations, Contacts])
class SecureDatabase extends _$SecureDatabase {
  static const String _kKeyStorageKey = 'spectre.db.k';
  static const String _kDbFileName = 'spectre.db';

  factory SecureDatabase({FlutterSecureStorage? secureStorage}) {
    final storage = secureStorage ?? _defaultStorage();
    // `instance` is referenced inside the lazy opener so that the opened
    // File can be cached on the instance for the wipe step. `late` is
    // safe: the LazyDatabase body only runs after this factory returns
    // and `instance` has been assigned.
    late SecureDatabase instance;

    final executor = LazyDatabase(() async {
      final keyHex = await _loadOrCreateKey(storage);
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, _kDbFileName));
      instance._dbFile = file;

      // Same-isolate constructor — see ISOLATE NOTE above for why we
      // are not using NativeDatabase.createInBackground.
      return NativeDatabase(
        file,
        setup: (db) {
          // PRAGMA key MUST be the first statement on the connection.
          // x'<hex>' tells SQLCipher to use the bytes as the raw key,
          // skipping PBKDF2.
          db.execute("PRAGMA key = \"x'$keyHex'\"");
          // Zero freed pages before they are re-encrypted to disk so a
          // deleted row's plaintext-shape (lengths, structure) cannot
          // leak via freed-page recovery if the cipher is ever broken.
          db.execute('PRAGMA cipher_secure_delete = ON');
          // Keep all temp tables and sort buffers in RAM. Disk-based
          // temp files would not inherit the SQLCipher encryption and
          // could leak intermediate query state in plaintext.
          db.execute('PRAGMA temp_store = MEMORY');
          // FK CASCADE is what makes "delete a conversation" predictably
          // remove all of its messages.
          db.execute('PRAGMA foreign_keys = ON');
        },
      );
    });

    instance = SecureDatabase._(executor, storage);
    return instance;
  }

  SecureDatabase._(QueryExecutor executor, this._secureStorage)
      : super(executor);

  final FlutterSecureStorage _secureStorage;
  File? _dbFile;

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          // v1 -> v2: add messages.plaintext (readable history, encrypted at
          // rest). Existing rows get null and keep showing the ciphertext
          // placeholder — there is no way to recover their plaintext.
          if (from < 2) {
            await m.addColumn(messages, messages.plaintext);
          }
        },
      );

  static FlutterSecureStorage _defaultStorage() => const FlutterSecureStorage(
        aOptions: AndroidOptions(
          encryptedSharedPreferences: true,
          resetOnError: false,
        ),
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
          synchronizable: false,
        ),
      );

  static Future<String> _loadOrCreateKey(FlutterSecureStorage storage) async {
    final existing = await storage.read(key: _kKeyStorageKey);
    if (existing != null) return existing;
    final rng = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = rng.nextInt(256);
    }
    final hex = _toHex(bytes);
    await storage.write(key: _kKeyStorageKey, value: hex);
    return hex;
  }

  static String _toHex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Forces the LazyDatabase to open now so any encryption or filesystem
  /// errors surface at app startup rather than on the first real query.
  Future<void> open() async {
    await customSelect('SELECT 1').get();
  }

  // -------------------------------------------------------------------------
  // Messages
  // -------------------------------------------------------------------------

  Future<void> insertMessage(Message m) async {
    await into(messages).insertOnConflictUpdate(
      MessagesCompanion(
        id: Value(m.id),
        conversationId: Value(m.conversationId),
        senderId: Value(m.senderId),
        ciphertext: Value(m.ciphertext),
        plaintext: Value(m.plaintext),
        timestamp: Value(m.timestamp.toUtc().millisecondsSinceEpoch),
        isRead: Value(m.isRead),
        expiresAt:
            Value(m.expiresAt?.toUtc().millisecondsSinceEpoch),
        isMine: Value(m.isMine),
      ),
    );
  }

  Future<List<Message>> getMessages(String conversationId) async {
    final rows = await (select(messages)
          ..where((m) => m.conversationId.equals(conversationId))
          ..orderBy(
              [(m) => OrderingTerm(expression: m.timestamp)]))
        .get();
    return rows.map(_messageFromRow).toList(growable: false);
  }

  /// Whether a message row with [id] already exists. The message id is a
  /// content hash of the ciphertext, so this doubles as a PERSISTENT replay
  /// guard: a relay redelivering an old sealed envelope produces the same id,
  /// and the receive path can drop it even across a restart (when the
  /// in-memory dedup set is empty). Reuses the existing table — no extra
  /// on-disk metadata.
  Future<bool> messageExists(String id) async {
    final row = await (select(messages)
          ..where((m) => m.id.equals(id))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  /// Hard-deletes every message whose expiry has passed. Called on every
  /// foreground resume so a device seized during the disappearing window
  /// has the shortest possible recovery window. Returns the count for
  /// observability — do NOT log per-row IDs.
  Future<int> deleteExpiredMessages() async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    return (delete(messages)
          ..where((m) =>
              m.expiresAt.isNotNull() &
              m.expiresAt.isSmallerThanValue(now)))
        .go();
  }

  // -------------------------------------------------------------------------
  // Conversations
  // -------------------------------------------------------------------------

  Future<void> insertConversation(Conversation c) async {
    await into(conversations).insertOnConflictUpdate(
      ConversationsCompanion(
        id: Value(c.id),
        recipientId: Value(c.recipientId),
        recipientPublicKey:
            Value(_base64ToBytes(c.recipientPublicKey)),
        lastMessageAt:
            Value(c.lastMessageAt?.toUtc().millisecondsSinceEpoch),
        isArchived: Value(c.isArchived),
        unreadCount: Value(c.unreadCount),
      ),
    );
  }

  /// Pins (or re-pins) the peer's serialized Signal identity key for a
  /// conversation. Used by the Sealed Sender receive path to TOFU-pin the
  /// peer identity on first contact and to detect a later key change. Keyed
  /// by conversation id so it updates only that row, leaving other fields
  /// (archive state, unread count) untouched.
  Future<int> updateConversationKey(
    String conversationId,
    String recipientPublicKeyB64,
  ) {
    return (update(conversations)..where((c) => c.id.equals(conversationId)))
        .write(ConversationsCompanion(
      recipientPublicKey: Value(_base64ToBytes(recipientPublicKeyB64)),
    ));
  }

  Future<List<Conversation>> getConversations() async {
    final rows = await (select(conversations)
          ..where((c) => c.isArchived.equals(false))
          ..orderBy([
            (c) => OrderingTerm(
                  expression: c.lastMessageAt,
                  mode: OrderingMode.desc,
                )
          ]))
        .get();
    return rows.map(_conversationFromRow).toList(growable: false);
  }

  // -------------------------------------------------------------------------
  // Contacts
  // -------------------------------------------------------------------------

  Future<void> insertContact(Contact c) async {
    await into(contacts).insertOnConflictUpdate(
      ContactsCompanion(
        id: Value(c.id),
        userId: Value(c.userId),
        displayName: Value(c.displayName),
        identityKeyFingerprint: Value(c.identityKeyFingerprint),
        isVerified: Value(c.isVerified),
        createdAt: Value(c.createdAt.toUtc().millisecondsSinceEpoch),
      ),
    );
  }

  Future<Contact?> getContact(String userId) async {
    final row = await (select(contacts)
          ..where((c) => c.userId.equals(userId))
          ..limit(1))
        .getSingleOrNull();
    if (row == null) return null;
    return _contactFromRow(row);
  }

  /// Sets [Contact.isVerified]. The boolean here represents human
  /// attestation after out-of-band fingerprint comparison — callers
  /// must NOT call this without a real user action behind it.
  Future<int> updateContactVerified(String userId, bool verified) {
    return (update(contacts)..where((c) => c.userId.equals(userId)))
        .write(ContactsCompanion(isVerified: Value(verified)));
  }

  /// Sets (or clears, with null) the local nickname for a contact. Local-only,
  /// never sent anywhere. `Value(null)` writes SQL NULL (clears it).
  Future<int> updateContactDisplayName(String userId, String? displayName) {
    return (update(contacts)..where((c) => c.userId.equals(userId)))
        .write(ContactsCompanion(displayName: Value(displayName)));
  }

  /// All contacts (one query) so the conversation list can resolve nicknames
  /// without an N+1 of getContact() per row.
  Future<List<Contact>> getAllContacts() async {
    final rows = await select(contacts).get();
    return rows.map(_contactFromRow).toList(growable: false);
  }

  /// Deletes a contact and every conversation linked to that peer in a
  /// single transaction. Messages tied to those conversations are removed
  /// transitively via the FK ON DELETE CASCADE on messages.conversationId.
  Future<void> deleteContact(String userId) async {
    await transaction(() async {
      await (delete(conversations)
            ..where((c) => c.recipientId.equals(userId)))
          .go();
      await (delete(contacts)..where((c) => c.userId.equals(userId))).go();
    });
  }

  /// Deletes a single conversation and all of its messages (cascade).
  Future<int> deleteConversation(String conversationId) {
    return (delete(conversations)
          ..where((c) => c.id.equals(conversationId)))
        .go();
  }

  // -------------------------------------------------------------------------
  // Panic wipe.
  //
  // Three layers, in increasing order of decisiveness:
  //
  //   1. Row-level scrub with cipher_secure_delete = ON, followed by a
  //      VACUUM that rewrites the file. After this step the new SQLCipher
  //      file no longer encodes any remnant of the old data.
  //
  //   2. File-level zero-overwrite + unlink. On flash media this is
  //      best-effort: wear-levelling means the original physical blocks
  //      may persist for an indeterminate period regardless of what the
  //      filesystem reports. We treat this layer as defense in depth.
  //
  //   3. Destroy the encryption key. THIS is the actual guarantee —
  //      without the key, anything that survives layers 1 and 2 is
  //      cryptographically unrecoverable. If only one step could be
  //      executed, this is the one that matters.
  // -------------------------------------------------------------------------

  Future<void> wipeDatabase() async {
    try {
      await transaction(() async {
        await customStatement('PRAGMA cipher_secure_delete = ON');
        await delete(messages).go();
        await delete(conversations).go();
        await delete(contacts).go();
      });
      // VACUUM cannot run inside a transaction.
      await customStatement('VACUUM');
    } catch (_) {
      // Even if scrubbing fails (corrupted DB, locked file, etc.) we
      // continue to file deletion and key destruction below. Failing
      // here is acceptable; failing layer 3 is not.
    }

    try {
      await close();
    } catch (_) {
      // Best effort.
    }

    final file = _dbFile;
    if (file != null && await file.exists()) {
      try {
        final length = await file.length();
        await file.writeAsBytes(Uint8List(length), flush: true);
      } catch (_) {
        // The cipher_secure_delete scrub above is the strong layer; this
        // zero-overwrite is belt-and-braces on top of it.
      }
      try {
        await file.delete();
      } catch (_) {
        // The key destruction below is the real protection.
      }
    }

    // Decisive step. After this point the on-disk bytes — if any survive
    // — are noise.
    await _secureStorage.delete(key: _kKeyStorageKey);
  }

  // -------------------------------------------------------------------------
  // Row -> model conversions
  // -------------------------------------------------------------------------

  static Message _messageFromRow(MessageRow r) => Message(
        id: r.id,
        conversationId: r.conversationId,
        senderId: r.senderId,
        ciphertext: Uint8List.fromList(r.ciphertext),
        plaintext: r.plaintext,
        timestamp:
            DateTime.fromMillisecondsSinceEpoch(r.timestamp, isUtc: true),
        isRead: r.isRead,
        expiresAt: r.expiresAt == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r.expiresAt!, isUtc: true),
        isMine: r.isMine,
      );

  static Conversation _conversationFromRow(ConversationRow r) => Conversation(
        id: r.id,
        recipientId: r.recipientId,
        recipientPublicKey: base64Encode(r.recipientPublicKey),
        lastMessageAt: r.lastMessageAt == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                r.lastMessageAt!,
                isUtc: true,
              ),
        isArchived: r.isArchived,
        unreadCount: r.unreadCount,
      );

  static Contact _contactFromRow(ContactRow r) => Contact(
        id: r.id,
        userId: r.userId,
        displayName: r.displayName,
        identityKeyFingerprint: r.identityKeyFingerprint,
        isVerified: r.isVerified,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(r.createdAt, isUtc: true),
      );

  static Uint8List _base64ToBytes(String s) {
    if (s.isEmpty) return Uint8List(0);
    return base64Decode(s);
  }
}
