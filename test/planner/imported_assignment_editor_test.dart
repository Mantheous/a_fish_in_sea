import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/planner/view/event_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../goldens/golden_app.dart' show pumpGoldenPage;

void main() {
  for (final schedule in [false, true]) {
    testWidgets(
      'imported text stays read-only through Save and refresh (schedule: $schedule)',
      (tester) async {
        final event = PlannerEvent(
          id: 'hw:canvas:event-assignment-42',
          subject: 'Assignment',
          notes: 'Source notes',
          location: 'Room 42',
          start: DateTime(2030, 1, 1, 9),
          end: DateTime(2030, 1, 1, 10),
          feedId: 'canvas',
          sourceUid: 'event-assignment-42',
          isTask: true,
          reminderMinutesBefore: 15,
        );
        await pumpGoldenPage(tester, EventEditorForm(existing: event));
        final context = tester.element(find.byType(EventEditorForm));
        final calendar = context.read<CalendarCubit>();
        final nodes = context.read<NodeCubit>();
        final feeds = context.read<FeedCubit>();
        calendar.addEvent(event);
        nodes.ensureNodeForFeedEvent(event);
        const feed = Feed(
          id: 'canvas',
          name: 'Canvas',
          url: 'https://example.com/class.ics',
          kind: FeedKind.canvas,
        );
        feeds.addFeed(feed);
        await tester.pumpAndSettle();
        for (final label in ['Title', 'Notes', 'Location']) {
          final field = find.byWidgetPredicate(
            (widget) =>
                widget is TextField && widget.decoration?.labelText == label,
          );
          expect(field, findsOneWidget);
          expect(tester.widget<TextField>(field).readOnly, isTrue);
        }
        if (schedule) {
          await tester.tap(find.byType(Switch).first);
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        final saved = calendar.byId(event.id)!;
        expect(saved.subject, event.subject);
        expect(saved.notes, event.notes);
        expect(saved.location, event.location);
        expect(saved.workTimeScheduled, schedule);

        final client = MockClient(
          (_) async => http.Response('''BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:event-assignment-42
DTSTAMP:20291101T120000Z
DTSTART:20300102T090000
DTEND:20300102T100000
SUMMARY:Updated assignment
DESCRIPTION:Updated notes
LOCATION:Room 43
END:VEVENT
END:VCALENDAR
''', 200),
        );
        final refresh = FeedCubit(
          calendarCubit: calendar,
          nodeCubit: nodes,
          icalService: IcalService(client: client),
          googleService: feeds.googleService,
          proxyBase: () => 'http://localhost:1',
        );
        try {
          refresh.addFeed(feed);
          await refresh.syncFeed(feed.id);
          expect(refresh.state.single.lastError, isNull);
          final synced = calendar.byId(event.id)!;
          expect(synced.subject, 'Updated assignment');
          expect(synced.notes, 'Updated notes');
          expect(synced.location, 'Room 43');
          expect(synced.workTimeScheduled, schedule);
          expect(
            synced.start,
            schedule ? saved.start : DateTime(2030, 1, 2, 9),
          );
          expect(synced.end, schedule ? saved.end : DateTime(2030, 1, 2, 10));
        } finally {
          await refresh.close();
          client.close();
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
