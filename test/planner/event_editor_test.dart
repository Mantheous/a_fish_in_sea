import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/event_editor.dart';
import 'package:a_fish_in_sea/reporting/bloc/places_cubit.dart';
import 'package:a_fish_in_sea/reporting/model/place.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../goldens/golden_app.dart';

void main() {
  testWidgets(
    'edit form mounts with non-preset reminder and Delete removes the event',
    (tester) async {
      final start = DateTime(2026, 10, 20, 9);
      final event = PlannerEvent(
        id: 'reminder-15-event',
        subject: 'Appointment with 15-minute reminder',
        start: start,
        end: start.add(const Duration(hours: 1)),
        // 15 comes from the post-save prompt choices, not the editor
        // preset list — it used to crash the reminder dropdown.
        reminderMinutesBefore: 15,
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

      expect(tester.takeException(), isNull);
      expect(find.byType(EventEditorForm), findsOneWidget);
      // The non-preset offset is surfaced so the form still mounts.
      expect(find.text('15 minutes before'), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(calendar.byId(event.id), isNull);
      expect(find.text('Event deleted'), findsOneWidget);
    },
  );

  testWidgets(
    'edit form mounts with stale placeId and Delete removes the event',
    (tester) async {
      final start = DateTime(2026, 10, 20, 9);
      final event = PlannerEvent(
        id: 'stale-place-event',
        subject: 'Event with deleted place',
        start: start,
        end: start.add(const Duration(hours: 1)),
        placeId: 'missing-place',
      );

      await pumpGoldenPage(
        tester,
        EventEditorForm(existing: event, title: 'Edit event'),
      );
      final calendar = BlocProvider.of<CalendarCubit>(
        tester.element(find.byType(EventEditorForm)),
      );
      final places = BlocProvider.of<PlacesCubit>(
        tester.element(find.byType(EventEditorForm)),
      );
      calendar.addEvent(event);
      places.addPlace(
        const Place(id: 'other-place', name: 'Home', lat: 0, lng: 0),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(EventEditorForm), findsOneWidget);
      expect(find.text('Unknown place'), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(calendar.byId(event.id), isNull);
      expect(find.text('Event deleted'), findsOneWidget);
    },
  );
}
