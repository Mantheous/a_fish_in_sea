import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../planner/calendar_move_scenario.dart';
import 'golden_app.dart';

void main() {
  for (final route in [(null, 'b'), ('a', null), ('a', 'b')]) {
    for (final legacy in [false, true]) {
      testWidgets('move $route retains recordings (legacy: $legacy)', (
        tester,
      ) async {
        await pumpGoldenPage(tester, const SizedBox());
        await verifyCalendarMove(
          tester,
          tester.element(find.byType(Scaffold).first),
          source: route.$1,
          destination: route.$2,
          legacy: legacy,
          golden: route.$1 == null && !legacy,
        );
      });
    }
  }
  testWidgets('failed create keeps the original recording', (tester) async {
    await pumpGoldenPage(tester, const SizedBox());
    await verifyCalendarMove(
      tester,
      tester.element(find.byType(Scaffold).first),
      source: 'a',
      destination: 'b',
      createFails: true,
    );
  });
}
