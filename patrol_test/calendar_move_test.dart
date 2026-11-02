import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

import '../test/planner/calendar_move_scenario.dart';

class _Storage extends Mock implements Storage {}

void main() {
  patrolTest('calendar moves retain recordings and the running timer', (
    $,
  ) async {
    $.tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
      $.tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );
    final storage = _Storage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    await $.pumpWidgetAndSettle(const MyApp());
    final stamp = DateTime.now().microsecondsSinceEpoch;
    await $(TextField).at(0).enterText('patrol-move-$stamp@example.com');
    await $(TextField).at(1).enterText('patrol-pass-1');
    await $('Create account').tap();
    await $(HomePage).waitUntilVisible();
    final context = $.tester.element(find.byType(HomePage));
    for (final route in [(null, 'b'), ('a', null), ('a', 'b')]) {
      await verifyCalendarMove(
        $.tester,
        context,
        source: route.$1,
        destination: route.$2,
      );
    }
    await verifyCalendarMove(
      $.tester,
      context,
      source: null,
      destination: 'b',
      repeating: true,
    );
  });
}
