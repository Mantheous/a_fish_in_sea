import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/recurring_payment_fixture.dart';

void main() {
  testWidgets(
    'recurring amount save refreshes only untouched future payments',
    (tester) async {
      final f = RecurringPaymentFixture();
      await f.pump(tester);
      final emissions = <Object>[];
      // The fixture closes the cubit and its broadcast stream in tearDown.
      f.nodes.stream.listen(emissions.add);
      await f.edit(tester);

      expect(emissions, hasLength(1));
      f.verify();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('recurring_payment_amount.png'),
      );
      f.verifyUndo();
      await tester.pumpAndSettle();
    },
  );
}
