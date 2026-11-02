import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/recurring_payment_fixture.dart';

void main() {
  testWidgets(
    'recurring amount save refreshes only untouched future payments',
    (tester) async {
      debugPrint('288 pump');
      final f = RecurringPaymentFixture();
      await f.pump(tester);
      debugPrint('288 pumped');
      final emissions = <Object>[];
      final subscription = f.nodes.stream.listen(emissions.add);
      await f.edit(tester);
      debugPrint('288 edited');
      await subscription.cancel();
      expect(emissions, hasLength(1));
      f.verify();
      debugPrint('288 verified');
      await f.showPage(tester);
      debugPrint('288 repumped');
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('recurring_payment_amount.png'),
      );
      debugPrint('288 captured');
      f.verifyUndo();
      debugPrint('288 undo tested');
    },
  );
}
