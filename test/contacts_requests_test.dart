import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spectre/core/models/contact.dart';
import 'package:spectre/core/models/conversation.dart';

Contact _contact({String? displayName, String? peerName}) => Contact(
      id: 'c',
      userId: 'u',
      identityKeyFingerprint: '00',
      createdAt: DateTime.utc(2020),
      displayName: displayName,
      peerName: peerName,
    );

void main() {
  group('peerLabel', () {
    test('uses the nickname when set', () {
      expect(peerLabel(_contact(displayName: 'alice'), 'TRUNC'), 'alice');
    });
    test('falls back when no contact', () {
      expect(peerLabel(null, 'TRUNC'), 'TRUNC');
    });
    test('falls back when nickname is empty', () {
      expect(peerLabel(_contact(displayName: ''), 'TRUNC'), 'TRUNC');
    });
    test('uses the peer self-name when no local nickname', () {
      expect(peerLabel(_contact(peerName: 'bob'), 'TRUNC'), 'bob');
    });
    test('local nickname wins over the peer self-name', () {
      expect(
        peerLabel(_contact(displayName: 'mine', peerName: 'theirs'), 'TRUNC'),
        'mine',
      );
    });
  });

  group('nextStateOnOutbound', () {
    test('replying to a pending request accepts it', () {
      expect(nextStateOnOutbound(ConversationRequestState.pending),
          ConversationRequestState.accepted);
    });
    test('accepted stays accepted', () {
      expect(nextStateOnOutbound(ConversationRequestState.accepted),
          ConversationRequestState.accepted);
    });
    test('outbound never silently un-blocks', () {
      expect(nextStateOnOutbound(ConversationRequestState.blocked),
          ConversationRequestState.blocked);
    });
  });

  group('shouldDropInbound', () {
    test('drops only blocked', () {
      expect(shouldDropInbound(ConversationRequestState.blocked), isTrue);
    });
    test('keeps null / accepted / pending', () {
      expect(shouldDropInbound(null), isFalse);
      expect(shouldDropInbound(ConversationRequestState.accepted), isFalse);
      expect(shouldDropInbound(ConversationRequestState.pending), isFalse);
    });
  });

  group('Conversation requestState round-trip', () {
    test('toMap -> fromMap preserves the state', () {
      for (final s in ConversationRequestState.values) {
        final c = Conversation(
          id: 'x',
          recipientId: 'peer',
          recipientPublicKey: base64Encode(<int>[1, 2, 3]),
          requestState: s,
        );
        expect(Conversation.fromMap(c.toMap()).requestState, s);
      }
    });

    test('a legacy row without request_state defaults to accepted', () {
      final legacy = <String, Object?>{
        'id': 'x',
        'recipient_id': 'peer',
        'recipient_public_key': base64Encode(<int>[1]),
        'last_message_at': 0,
        'is_archived': 0,
        // no 'request_state'
      };
      expect(Conversation.fromMap(legacy).requestState,
          ConversationRequestState.accepted);
    });

    test('an out-of-range index clamps to accepted', () {
      final weird = <String, Object?>{
        'id': 'x',
        'recipient_id': 'peer',
        'recipient_public_key': base64Encode(<int>[1]),
        'last_message_at': 0,
        'is_archived': 0,
        'request_state': 99,
      };
      expect(Conversation.fromMap(weird).requestState,
          ConversationRequestState.accepted);
    });
  });
}
