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
  for (final legacy in [false, true]) {
    testWidgets('repeating move survives refresh (legacy: $legacy)', (
      tester,
    ) async {
      await pumpGoldenPage(tester, const SizedBox());
      await verifyCalendarMove(
        tester,
        tester.element(find.byType(Scaffold).first),
        source: null,
        destination: 'b',
        repeating: true,
        legacy: legacy,
      );
    });
  }
  for (final refreshFails in [false, true]) {
    testWidgets(
      'unconfirmed repeating transfer keeps original ($refreshFails)',
      (tester) async {
        await pumpGoldenPage(tester, const SizedBox());
        await verifyCalendarMove(
          tester,
          tester.element(find.byType(Scaffold).first),
          source: null,
          destination: 'b',
          repeating: true,
          refreshFails: refreshFails,
          missingOccurrence: !refreshFails,
        );
      },
    );
  }
  for (final destination in [null, 'b']) {
    for (final legacy in [false, true]) {
      testWidgets(
        'failed delete to $destination keeps one recording owner (legacy: $legacy)',
        (tester) async {
          await pumpGoldenPage(tester, const SizedBox());
          await verifyCalendarMove(
            tester,
            tester.element(find.byType(Scaffold).first),
            source: 'a',
            destination: destination,
            legacy: legacy,
            deleteFails: true,
          );
        },
      );
    }
  }
  for (final source in [null, 'a']) {
    for (final legacy in [false, true]) {
      testWidgets(
        'dismiss during $source → Google creation (legacy: $legacy)',
        (tester) async {
          await pumpGoldenPage(tester, const SizedBox());
          await verifyCalendarMove(
            tester,
            tester.element(find.byType(Scaffold).first),
            source: source,
            destination: 'b',
            legacy: legacy,
            dismissDuringCreate: true,
          );
        },
      );
    }
  }
  for (final destination in [null, 'b']) {
    for (final legacy in [false, true]) {
      for (final checkFails in [false, true]) {
        testWidgets('lost delete response to $destination retains recordings '
            '(legacy: $legacy, check fails: $checkFails)', (tester) async {
          await pumpGoldenPage(tester, const SizedBox());
          await verifyCalendarMove(
            tester,
            tester.element(find.byType(Scaffold).first),
            source: 'a',
            destination: destination,
            legacy: legacy,
            deleteFails: true,
            deleteApplied: true,
            deleteCheckFails: checkFails,
          );
        });
      }
    }
    testWidgets('unavailable delete check to $destination retains one owner', (
      tester,
    ) async {
      await pumpGoldenPage(tester, const SizedBox());
      await verifyCalendarMove(
        tester,
        tester.element(find.byType(Scaffold).first),
        source: 'a',
        destination: destination,
        deleteFails: true,
        deleteCheckFails: true,
      );
    });
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
