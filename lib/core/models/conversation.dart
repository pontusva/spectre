import 'dart:convert';
import 'dart:typed_data';

/// Message-request state of a conversation (one-sided / Signal-style):
///   * [accepted] — in the main Chats list. A conversation I start, or a
///     request I've accepted.
///   * [pending]  — an inbound from a peer I haven't accepted; shown in the
///     Requests inbox, not Chats.
///   * [blocked]  — hidden everywhere; inbound from this peer is dropped. The
///     row is KEPT (it is the blocklist); never deleted.
/// Stored as the enum index in `conversations.requestState` (default 0).
enum ConversationRequestState { accepted, pending, blocked }

/// Pure transition for an OUTBOUND message to [current]: replying to a pending
/// request accepts it; accepted stays accepted; a blocked peer is never
/// silently un-blocked. Unit-tested.
ConversationRequestState nextStateOnOutbound(ConversationRequestState current) {
  return current == ConversationRequestState.pending
      ? ConversationRequestState.accepted
      : current;
}

/// Pure inbound gate: drop iff the existing conversation is blocked. A missing
/// row ([existing] null) is never blocked. Unit-tested.
bool shouldDropInbound(ConversationRequestState? existing) =>
    existing == ConversationRequestState.blocked;

/// A 1:1 conversation with a single peer.
///
/// Notes on key pinning:
///   * [recipientPublicKey] is the peer's serialized Signal identity
///     public key, base64-encoded for in-model handling. It is pinned at
///     conversation-creation time — any future session establishment
///     must match this exact key, otherwise the UI is expected to
///     surface a "safety number changed" warning rather than silently
///     re-negotiating. Silently accepting a new identity key is the
///     textbook MITM vector, and for activists it's the difference
///     between "your messages are private" and "your messages are
///     copied to an adversary".
class Conversation {
  final String id;

  /// Opaque random identifier of the peer (e.g. base64url of 32 random
  /// bytes — never a phone number, email, or other PII).
  final String recipientId;

  /// Base64-encoded Signal identity public key for the peer. Stored as
  /// BLOB in the database; surfaced as a string in the model so it can
  /// be safely passed around (logs, JSON debug dumps in dev builds,
  /// etc.) without dragging Uint8List buffers everywhere.
  final String recipientPublicKey;

  final DateTime? lastMessageAt;
  final bool isArchived;

  /// Count of unread messages in this conversation. Derived by a
  /// `COUNT(*)` query against the messages table, NOT a column —
  /// keeping it derived avoids the classic "counter drifted out of
  /// sync with reality" bug class. Defaults to 0 when not provided.
  final int unreadCount;

  /// Message-request state. Defaults to accepted (a conversation I create, or a
  /// legacy row, is never a request).
  final ConversationRequestState requestState;

  const Conversation({
    required this.id,
    required this.recipientId,
    required this.recipientPublicKey,
    this.lastMessageAt,
    this.isArchived = false,
    this.unreadCount = 0,
    this.requestState = ConversationRequestState.accepted,
  });

  /// Safe display label for the conversation.
  ///
  /// OPSEC: we always truncate. Even when a verified contact name is
  /// eventually wired in at the UI layer, this getter intentionally
  /// returns only a short prefix of the opaque recipient ID — never
  /// the whole thing — because:
  ///   - Full IDs are sensitive: anyone who shoulder-surfs a screen or
  ///     captures it in a screenshot/screen-recording learns a stable
  ///     handle that ties the user to a remote account.
  ///   - Truncation is a one-way mapping. An attacker glimpsing the
  ///     truncated prefix on a lockscreen notification can't expand
  ///     it back into the full account identifier.
  ///   - The UI layer can layer a verified [Contact.displayName] on
  ///     top if available; this getter is the *fallback*, and the
  ///     fallback must be safe by default.
  String get displayName {
    // 8 chars of base64url ≈ 48 bits — enough to disambiguate among a
    // handful of recent chats while leaving the remaining ~200+ bits
    // of the ID off-screen.
    if (recipientId.length <= 8) return recipientId;
    return '${recipientId.substring(0, 8)}…';
  }

  /// Builds from a sqflite row. [unreadCount] is passed in by the
  /// caller from the messages query.
  factory Conversation.fromMap(
    Map<String, Object?> map, {
    int unreadCount = 0,
  }) {
    final keyValue = map['recipient_public_key'];
    final String keyB64;
    if (keyValue is String) {
      keyB64 = keyValue;
    } else if (keyValue is Uint8List) {
      keyB64 = base64Encode(keyValue);
    } else if (keyValue is List<int>) {
      keyB64 = base64Encode(keyValue);
    } else {
      throw ArgumentError(
        'recipient_public_key must be BLOB or base64 String',
      );
    }

    final lastMsMs = map['last_message_at'] as int?;
    return Conversation(
      id: map['id'] as String,
      recipientId: map['recipient_id'] as String,
      recipientPublicKey: keyB64,
      lastMessageAt: (lastMsMs == null || lastMsMs == 0)
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastMsMs, isUtc: true),
      isArchived: (map['is_archived'] as int) != 0,
      unreadCount: unreadCount,
      requestState: _requestStateFromIndex(map['request_state'] as int?),
    );
  }

  static ConversationRequestState _requestStateFromIndex(int? idx) {
    if (idx == null ||
        idx < 0 ||
        idx >= ConversationRequestState.values.length) {
      return ConversationRequestState.accepted;
    }
    return ConversationRequestState.values[idx];
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'id': id,
      'recipient_id': recipientId,
      // Decode the base64 back to bytes for the BLOB column.
      'recipient_public_key': base64Decode(recipientPublicKey),
      'last_message_at': lastMessageAt?.toUtc().millisecondsSinceEpoch ?? 0,
      'is_archived': isArchived ? 1 : 0,
      'request_state': requestState.index,
      // unreadCount is intentionally not persisted — see field doc.
    };
  }

  Conversation copyWith({
    DateTime? lastMessageAt,
    bool? isArchived,
    int? unreadCount,
    ConversationRequestState? requestState,
  }) {
    return Conversation(
      id: id,
      recipientId: recipientId,
      recipientPublicKey: recipientPublicKey,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      isArchived: isArchived ?? this.isArchived,
      unreadCount: unreadCount ?? this.unreadCount,
      requestState: requestState ?? this.requestState,
    );
  }
}
