import 'dart:typed_data';

/// A message as it lives in the encrypted local database.
///
/// IMPORTANT — DO NOT ADD A `plaintext` / `body` / `text` FIELD HERE.
///
/// This model is the boundary between the encrypted-at-rest database
/// (`secure_database.dart`) and the rest of the app. Holding only
/// [ciphertext] guarantees that:
///   1. Plaintext never leaks into any persistence layer by accident
///      (sqflite cache, isolate snapshots, crash dumps, hot-reload
///      state, ListView item-cache, etc.). A model with a plaintext
///      field will be copied into all of those places without the
///      developer realising it.
///   2. Decryption stays an explicit, auditable step: a caller has to
///      pass [ciphertext] through [SessionManager.decryptMessage] to
///      get a `String`, and that `String` is held only inside the UI
///      widget's build scope before being dropped on rebuild. If you
///      add a plaintext field "for convenience", the threat model
///      breaks silently — there is no compiler error, only a forensic
///      finding months later.
///   3. Panic wipe is meaningful: destroying the SQLCipher key makes
///      the ciphertext column unrecoverable. If we also cached
///      plaintext somewhere, the wipe would have to chase it down
///      across every model copy in memory and on disk.
///
/// If you find yourself wanting a plaintext field, instead:
///   - decrypt at the View layer, hold the string in a local variable;
///   - or add a transient, non-persisted `DecryptedMessage` value type
///     that lives only for the duration of one render and is not
///     stored in any list/cache/state container.
class Message {
  /// UUID for the message row. Generated client-side so that the relay
  /// server never sees a server-assigned ID that could be used to
  /// correlate accounts.
  final String id;

  final String conversationId;
  final String senderId;

  /// Signal Protocol ciphertext envelope (the base64-encoded blob
  /// produced by [SessionManager.encryptMessage], stored as raw bytes).
  /// This is the ONLY representation of the message content kept in
  /// the model.
  final Uint8List ciphertext;

  final DateTime timestamp;
  final bool isRead;

  /// Absolute disappearing-message expiry. `null` means the message
  /// does not auto-delete. We store an absolute instant rather than a
  /// duration so the deletion can't be cheated by changing the device
  /// clock backwards without also tampering with stored data.
  final DateTime? expiresAt;

  /// True if the local user is the sender. Derived at load time from
  /// `senderId == currentUserId` — it is NOT persisted to the database
  /// (the same row would have a different `isMine` value if exported to
  /// another device, so it has no business being on disk).
  final bool isMine;

  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.ciphertext,
    required this.timestamp,
    this.isRead = false,
    this.expiresAt,
    this.isMine = false,
  });

  /// True iff [expiresAt] is set and already in the past. Use this as
  /// a UI-level filter — the database sweep in
  /// [SecureDatabase.deleteExpiredMessages] is the source of truth for
  /// actually removing rows.
  bool get isExpired {
    final exp = expiresAt;
    if (exp == null) return false;
    return DateTime.now().toUtc().isAfter(exp.toUtc());
  }

  /// Builds a [Message] from a sqflite row.
  ///
  /// [isMine] is derived by the caller from the current user's ID and
  /// passed in explicitly — see the field doc above for why this is
  /// not a column.
  factory Message.fromMap(
    Map<String, Object?> map, {
    bool isMine = false,
  }) {
    final expiresAtMs = map['expires_at'] as int?;
    return Message(
      id: map['id'] as String,
      conversationId: map['conversation_id'] as String,
      senderId: map['sender_id'] as String,
      ciphertext: _readBytes(map['ciphertext']),
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        map['timestamp'] as int,
        isUtc: true,
      ),
      isRead: (map['is_read'] as int) != 0,
      expiresAt: expiresAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expiresAtMs, isUtc: true),
      isMine: isMine,
    );
  }

  /// Serializes for sqflite insert/update. Note the absence of an
  /// `is_mine` key — see the field doc above.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'id': id,
      'conversation_id': conversationId,
      'sender_id': senderId,
      'ciphertext': ciphertext,
      'timestamp': timestamp.toUtc().millisecondsSinceEpoch,
      'is_read': isRead ? 1 : 0,
      'expires_at': expiresAt?.toUtc().millisecondsSinceEpoch,
    };
  }

  Message copyWith({
    bool? isRead,
    DateTime? expiresAt,
    bool? isMine,
  }) {
    return Message(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      ciphertext: ciphertext,
      timestamp: timestamp,
      isRead: isRead ?? this.isRead,
      expiresAt: expiresAt ?? this.expiresAt,
      isMine: isMine ?? this.isMine,
    );
  }

  static Uint8List _readBytes(Object? value) {
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    throw ArgumentError(
      'ciphertext column must be BLOB (Uint8List or List<int>)',
    );
  }
}
