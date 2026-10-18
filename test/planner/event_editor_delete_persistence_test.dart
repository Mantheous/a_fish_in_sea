import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/event_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../goldens/golden_app.dart';

void main() {
  testWidgets(
    'delete stays reachable while editing and remains deleted after Undo expires',
    (tester) async {
      final start = DateTime(2026, 10, 20, 9);
      final event = PlannerEvent(
        id: 'local-event',
        subject: 'Weekly planning',
        start: start,
        end: start.add(const Duration(hours: 1)),
      );

      await pumpGoldenPage(
        tester,
        EventEditorForm(existing: event, title: 'Edit event'),
      );
      final calendar = BlocProvider.of<CalendarCubit>(
        tester.element(find.byType(EventEditorForm)),
      );
      calendar.addEvent(event);
      await tester.pumpAndSettle();

      final delete = find.text('Delete');
      final initialPosition = tester.getTopLeft(delete);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -900),
      );
      await tester.pumpAndSettle();
      expect(delete, findsOneWidget);
      expect(tester.getTopLeft(delete).dy, closeTo(initialPosition.dy, 1));

      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(calendar.byId(event.id), isNull);
      expect(find.text('Event deleted'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('Undo'), findsNothing);
      expect(calendar.byId(event.id), isNull);
    },
  );
}
