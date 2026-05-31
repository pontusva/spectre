import 'dart:typed_data';

/// A message as it lives in the encrypted local database.
///
/// POSTURE NOTE — [plaintext] is persisted, encrypted AT REST.
///
/// This model originally held ONLY [ciphertext], to keep plaintext off disk
/// entirely. That made history unreadable after a restart (the ratchet
/// ciphertext can never be re-decrypted), which is unusable for a messenger.
/// We therefore made a deliberate, documented tradeoff: persist [plaintext] in
/// the SQLCipher-encrypted database (key in the OS keystore) — the same
/// "encrypted at rest" posture as Signal. See SPECTRE_DEVLOG Principle #2 and
/// the `messages.plaintext` column comment in secure_database.dart.
///
/// What still holds:
///   - Panic wipe stays meaningful: destroying the SQLCipher key makes the
///     plaintext column unrecoverable along with everything else.
///   - The disappearing-message sweep deletes the row (and thus the plaintext).
/// What changed:
///   - A seized, UNLOCKED device can read stored history. That is the accepted
///     cost of readable history; the mitigation is panic-wipe + short
///     disappearing timers, not absence-from-disk.
///
/// Keep [plaintext] confined to this persistence boundary and the chat view —
/// do NOT fan it out into long-lived caches/providers beyond what the UI needs.
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

  /// Decrypted message text, persisted encrypted-at-rest (see class doc).
  /// Null when unknown — e.g. an inbound message that never decrypted, or a
  /// pre-v2 row from before this column existed; the UI then shows the
  /// ciphertext placeholder.
  final String? plaintext;

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
    this.plaintext,
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
      plaintext: map['plaintext'] as String?,
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
      'plaintext': plaintext,
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
      plaintext: plaintext,
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
