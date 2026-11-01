import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/bank_settlement_fixture.dart';

void main() {
  testWidgets(
    'bank sync shows one posted purchase and preserves budget spending',
    (tester) async {
      final f = BankSettlementFixture();
      await f.pump(tester);
      await tester.tap(find.text('Sync Transactions'));
      await tester.pumpAndSettle();
      f.verify();
      expect(find.text('Coffee Shop'), findsOneWidget);
      await expectLater(
        find.byType(Scrollable),
        matchesGoldenFile('bank_settlement.posted.png'),
      );
    },
  );
}
