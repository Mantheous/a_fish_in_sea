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

  testWidgets(
    'renaming a recurring payment before its amount still refreshes forecasts',
    (tester) async {
      final f = RecurringPaymentFixture();
      await f.pump(tester);
      expect(
        f.nodes.updateNode(f.template.copyWith(title: 'Monthly rent')),
        isNull,
      );
      expect(f.nodes.byId(f.refreshedId)!.title, 'Rent');
      await tester.pumpAndSettle();
      f.before = List.of(f.nodes.state);
      f.undo.resetHistory();
      final emissions = <Object>[];
      f.nodes.stream.listen(emissions.add);

      await f.edit(tester);

      expect(emissions, hasLength(1));
      expect(f.nodes.byId(f.template.id)!.title, 'Monthly rent');
      f.verify();
      f.verifyUndo();
      expect(f.nodes.byId(f.template.id)!.title, 'Monthly rent');
      await tester.pumpAndSettle();
    },
  );
}
