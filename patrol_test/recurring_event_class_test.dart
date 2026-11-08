import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

import '../test/goldens/golden_app.dart' show MockStorage;
import '../test/goldens/recurring_event_editor_test.dart' show linkAndEditRecurringEvent;

void main() {
  patrolTest('repeating Google event links to a class and opens its editor', ($) async {
    $.tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown($.tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    await $.pumpWidget(const MyApp());
    final stamp = DateTime.now().microsecondsSinceEpoch;
    await $(TextField).at(0).enterText('patrol-class-$stamp@example.com');
    await $(TextField).at(1).enterText('patrol-pass-1');
    await $('Create account').tap();
    await $.pumpAndSettle();
    await $(Icons.menu).tap();
    await $('Calendar').tap();
    await $.pumpAndSettle();
    await linkAndEditRecurringEvent($.tester,
      $.tester.element(find.byType(CalendarPage)));
  });
}
