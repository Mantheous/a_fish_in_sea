import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/event_editor.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import '../test/goldens/golden_app.dart';

/// Regression for issue #48: an event carrying a non-preset reminder offset
/// (e.g. 15 minutes, offered by the post-save prompt but absent from the
/// editor preset list) used to crash the edit form, blocking Delete.
///
/// Run headless against the dev API server:
///   patrol test --device chrome --web-headless \
///     --target patrol_test/event_editor_test.dart \
///     --dart-define=SERVER_URL=http://127.0.0.1:8000
///
/// The deleted event is local-only, so no server round trip is involved.
void main() {
  patrolTest(
    'edit form with non-preset reminder mounts and Delete removes the event',
    ($) async {
      final start = DateTime(2026, 10, 20, 9);
      final event = PlannerEvent(
        id: 'reminder-15-event',
        subject: 'Appointment with 15-minute reminder',
        start: start,
        end: start.add(const Duration(hours: 1)),
        reminderMinutesBefore: 15,
      );

      await pumpGoldenPage(
        $.tester,
        EventEditorForm(existing: event, title: 'Edit event'),
      );
      final calendar = BlocProvider.of<CalendarCubit>(
        $.tester.element(find.byType(EventEditorForm)),
      );
      calendar.addEvent(event);
      await $.tester.pumpAndSettle();

      expect($.tester.takeException(), isNull);
      expect(find.byType(EventEditorForm), findsOneWidget);
      expect(find.text('15 minutes before'), findsOneWidget);

      await $.tester.tap(find.text('Delete'));
      await $.tester.pumpAndSettle();
      expect($.tester.takeException(), isNull);
      expect(calendar.byId(event.id), isNull);
      expect(find.text('Event deleted'), findsOneWidget);
    },
  );
}
