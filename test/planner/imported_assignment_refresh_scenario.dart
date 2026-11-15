import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
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

/// The phone modal keeps its opening event while a class refresh arrives.
Future<void> verifyAssignmentRefreshDuringEdit(
  WidgetTester tester,
  BuildContext context, {
  required FeedKind kind,
}) async {
  final calendar = context.read<CalendarCubit>();
  final nodes = context.read<NodeCubit>();
  final feeds = context.read<FeedCubit>();
  final day = DateTime(2030, 1, 2);
  final feed = Feed(
    id: 'editor-refresh-${kind.name}',
    name: kind.name,
    url: 'https://example.com/class.ics',
    kind: kind,
  );
  feeds.addFeed(feed);
  final allDay = kind == FeedKind.learningSuite;
  var source = PlannerEvent(
    id: 'hw:${feed.id}:event-assignment-refresh',
    subject: 'Independently scheduled assignment',
    start: allDay ? day : DateTime(2030, 1, 2, 9),
    end: allDay ? DateTime(2030, 1, 5) : DateTime(2030, 1, 2, 9),
    allDay: allDay,
    feedId: feed.id,
    sourceUid: 'event-assignment-refresh',
    isTask: true,
  );
  final block = PlannerEvent(
    id: '${feed.id}-work-block',
    subject: 'Work on assignment',
    start: DateTime(2030, 1, 2, 14),
    end: DateTime(2030, 1, 2, 15, 30),
    isTask: true,
    taskId: source.id,
  );
  final task = Node(
    id: source.id,
    title: source.subject,
    createdAt: day,
    sourceEventId: source.id,
    feedId: feed.id,
    calendarEventId: block.id,
    schedule: ScheduleFacet(
      due: DateTime(2030, 1, 3, 17),
      start: block.start,
      end: block.end,
    ),
  );
  calendar.addEvent(source);
  calendar.addEvent(block);
  nodes.addNode(task);
  var sourceInterval = '';
  final client = MockClient(
    (_) async => http.Response('''BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:event-assignment-refresh
DTSTAMP:20291101T120000Z
$sourceInterval
SUMMARY:Independently scheduled assignment
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
  refresh.addFeed(feed);

  void expectPlansPreserved({required bool done}) {
    final saved = calendar.byId(source.id)!;
    expect(saved.start, source.start);
    expect(saved.end, source.end);
    expect(saved.allDay, source.allDay);
    expect(saved.workTimeScheduled, isFalse);
    expect(saved.done, done);
    expect(nodes.byId(task.id)!.schedule, task.schedule);
    expect(nodes.byId(task.id)!.calendarEventId, block.id);
    expect(nodes.byId(task.id)!.isDone, done);
    expect(calendar.byId(block.id), block);
  }

  try {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    await tester.pumpAndSettle();
    for (final complete in [false, true]) {
      final opening = calendar.byId(source.id)!;
      final editing = showEventEditor(context, existing: opening);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(EventEditorForm)).width, lessThan(720));

      // Change start/end and allDay in both directions without touching the
      // editor's time controls. The task's separate work block stays put.
      final nextAllDay = !opening.allDay;
      source = source.copyWith(
        start: nextAllDay ? day : DateTime(2030, 1, 2, 11),
        end: nextAllDay ? DateTime(2030, 1, 6) : DateTime(2030, 1, 2, 12),
        allDay: nextAllDay,
      );
      sourceInterval = nextAllDay
          ? 'DTSTART;VALUE=DATE:20300102\nDTEND;VALUE=DATE:20300106'
          : 'DTSTART:20300102T110000\nDTEND:20300102T120000';
      await refresh.syncFeed(feed.id);
      expect(refresh.state.single.lastError, isNull);
      expect(refresh.state.single.lastSyncAt, isNotNull);
      await tester.pumpAndSettle();
      expect(
        tester.widget<EventEditorForm>(find.byType(EventEditorForm)).existing,
        opening,
      );
      expectPlansPreserved(done: false);

      if (complete) {
        final completed = find.widgetWithText(CheckboxListTile, 'Completed');
        await tester.ensureVisible(completed);
        await tester.tap(completed);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(await editing, isTrue);
      expectPlansPreserved(done: complete);

      await refresh.syncFeed(feed.id);
      expect(refresh.state.single.lastError, isNull);
      await tester.pumpAndSettle();
      expectPlansPreserved(done: complete);
      final details = showEventDetail(
        context,
        event: calendar.byId(source.id)!,
      );
      await tester.pumpAndSettle();
      expect(find.text('Planned 2:00 PM – 3:30 PM (90m)'), findsOneWidget);
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      await details;
    }
  } finally {
    await refresh.close();
    client.close();
    await tester.binding.setSurfaceSize(null);
    await tester.pumpAndSettle();
  }
  expect(tester.takeException(), isNull);
}
