import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

class MockStorage extends Mock implements Storage {}

/// Calendar +Event cancel flow: a newcomer opens the calendar, starts a new
/// event, cancels it, and lands back on the calendar with nothing saved and
/// no form left open (issue #18: a teal selection outline lingered on the
/// draft's old slot after Cancel).
///
/// Run against the live dev API server:
///   patrol test --device chrome --web-headless \
///     --target patrol_test/calendar_cancel_test.dart \
///     --dart-define=SERVER_URL=http://127.0.0.1:8000
///
/// Uses a unique email per run so reruns never 409. Leaves one junk
/// account per run on the dev server.
void main() {
  patrolTest('calendar cancel discards the unsaved draft', ($) async {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    await $.pumpWidgetAndSettle(const MyApp());

    final stamp = DateTime.now().millisecondsSinceEpoch;
    await $(TextField).at(0).enterText('patrol-cal-cancel-$stamp@example.com');
    await $(TextField).at(1).enterText('patrol-pass-1');
    await $('Create account').tap();
    await $.pumpAndSettle();

    expect(find.byType(HomePage), findsOneWidget);

    await $(Icons.menu).tap();
    await $.pumpAndSettle();
    await $('Calendar').tap();
    await $.pumpAndSettle();

    expect(find.byType(CalendarPage), findsOneWidget);

    // + Event opens the unsaved draft (editor sheet or side panel,
    // depending on viewport width).
    await $('Event').tap();
    await $.pumpAndSettle();
    expect($('Cancel').visible, true);

    await $('Cancel').tap();
    await $.pumpAndSettle();

    // Cancelling closes the form and saves nothing: still on the
    // calendar with no form left open.
    expect(find.byType(CalendarPage), findsOneWidget);
    expect($('Cancel').visible, false);
  });
}
