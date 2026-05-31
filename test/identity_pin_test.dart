import 'package:flutter_test/flutter_test.dart';
import 'package:spectre/services/message_service.dart';

/// Unit tests for the TOFU identity-pin decision (NEW-HIGH-1). The decision is
/// pure, so it is tested without a database or session store.
void main() {
  test('nothing pinned yet -> pin on first use', () {
    expect(
      MessageService.decideIdentityPin('', 'AAAAcurrentkey'),
      IdentityPinDecision.pinFirstUse,
    );
  });

  test('current equals pinned -> matched', () {
    expect(
      MessageService.decideIdentityPin('BQ==pinnedkey', 'BQ==pinnedkey'),
      IdentityPinDecision.matched,
    );
  });

  test('current differs from pinned -> changed (do not silently re-pin)', () {
    expect(
      MessageService.decideIdentityPin('BQ==oldkey', 'BQ==newkey'),
      IdentityPinDecision.changed,
    );
  });
}
