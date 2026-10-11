import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:a_fish_in_sea/planner/view/event_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../goldens/golden_app.dart';

/// Sidebar edits must move the calendar highlight live: the edit form owns
/// its field state until Save, so the page keeps a preview that swaps the
/// tile in place. Nothing is stored until Save.
void main() {
  PlannerEvent nineToTen() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, 9);
    return PlannerEvent(
      id: 'e1',
      subject: 'Morning standup',
      start: start,
      end: start.add(const Duration(hours: 1)),
    );
  }

  CalendarCubit calendarOf(WidgetTester tester) =>
      BlocProvider.of<CalendarCubit>(
        tester.element(find.byType(CalendarPage)),
      );

  Future<void> openEditor(WidgetTester tester) async {
    await pumpGoldenPage(tester, const CalendarPage());
    calendarOf(tester).addEvent(nineToTen());
    // Two frames: the first rebuilds the calendar, the second flushes
    // SfCalendar's internal appointment layout pass.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('Morning standup'));
    await tester.pumpAndSettle();
    expect(find.text('Event details'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit event'), findsOneWidget);
  }

  testWidgets('toggling all-day emits a same-id preview without saving',
      (tester) async {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    PlannerEvent? captured;
    await pumpGoldenPage(
      tester,
      EventEditorForm(
        existing: nineToTen(),
        onDraftChanged: (preview) => captured = preview,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(captured, isNull);

    await tester.tap(find.byType(Switch).first);
    await tester.pump();

    // Same id so the calendar swaps the tile in place; the stored event
    // is untouched (the form never writes the cubit itself).
    expect(captured?.id, 'e1');
    expect(captured?.allDay, isTrue);
    expect(captured?.start, day);
    expect(captured?.end, day.add(const Duration(days: 1)));
  });

  testWidgets('retitling retargets the tile label without saving',
      (tester) async {
    await openEditor(tester);
    final calendar = calendarOf(tester);

    await tester.enterText(find.byType(TextField).first, 'Evening review');
    // Title keystrokes are debounced before the preview emits.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // Field + tile both show the new title; nothing saved yet.
    expect(find.text('Evening review'), findsNWidgets(2));
    expect(calendar.byId('e1')!.subject, 'Morning standup');
  });
}
