import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

/// An assignment scheduled through Tasks has a separate work-block event.
/// Saving its source event must leave that independently chosen plan alone.
Future<void> verifyUnchangedAssignmentSave(
  WidgetTester tester, {
  FeedKind kind = FeedKind.canvas,
  bool allDay = true,
  int sourceDays = 1,
}) async {
  final context = tester.element(find.byType(CalendarPage));
  final calendar = context.read<CalendarCubit>();
  final nodes = context.read<NodeCubit>();
  final day = DateTime(2030, 1, 2);
  final feedId = 'unchanged-${kind.name}-$allDay';
  final feed = Feed(
    id: feedId,
    name: kind.name,
    url: 'https://example.com/class.ics',
    kind: kind,
  );
  context.read<FeedCubit>().addFeed(feed);
  final start = allDay ? day : DateTime(2030, 1, 2, 9);
  final assignment = PlannerEvent(
    id: 'hw:$feedId:event-assignment-independent',
    subject: 'Independently scheduled assignment',
    start: start,
    end: allDay ? DateTime(2030, 1, 2 + sourceDays) : start,
    allDay: allDay,
    feedId: feedId,
    sourceUid: 'event-assignment-independent',
    isTask: true,
  );
  final block = PlannerEvent(
    id: '$feedId-work-block',
    subject: 'Work on assignment',
    start: DateTime(2030, 1, 2, 14),
    end: DateTime(2030, 1, 2, 15, 30),
    isTask: true,
    taskId: assignment.id,
  );
  final task = Node(
    id: assignment.id,
    title: assignment.subject,
    createdAt: day,
    sourceEventId: assignment.id,
    feedId: feedId,
    calendarEventId: block.id,
    schedule: ScheduleFacet(
      due: assignment.start,
      start: block.start,
      end: block.end,
      allDay: false,
    ),
  );
  calendar.addEvent(assignment);
  calendar.addEvent(block);
  nodes.addNode(task);
  context.read<SettingsCubit>().setDayHours(8, 18);
  await tester.tap(find.text('Day'));
  await tester.pumpAndSettle();
  final controller = tester
      .widget<SfCalendar>(find.byType(SfCalendar))
      .controller!;
  controller.displayDate = day;
  controller.selectedDate = day;
  await tester.pumpAndSettle();
  final tile = find.byKey(ValueKey('tile:${assignment.id}'));
  expect(tile, findsOneWidget);
  await tester.tap(tile);
  await tester.pumpAndSettle();

  final sourceInterval = allDay
      ? 'DTSTART;VALUE=DATE:20300102\n'
            'DTEND;VALUE=DATE:2030010${2 + sourceDays}'
      : 'DTSTART:20300102T090000\nDTEND:20300102T090000';
  final client = MockClient(
    (_) async => http.Response('''BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:event-assignment-independent
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
    googleService: context.read<FeedCubit>().googleService,
    proxyBase: () => 'http://localhost:1',
  );
  refresh.addFeed(feed);
  void expectPlanUnchanged() {
    final saved = calendar.byId(assignment.id)!;
    expect(saved.start, assignment.start);
    expect(saved.end, assignment.end);
    expect(saved.allDay, assignment.allDay);
    expect(saved.workTimeScheduled, assignment.workTimeScheduled);
    expect(nodes.byId(task.id)!.schedule, task.schedule);
    expect(nodes.byId(task.id)!.calendarEventId, block.id);
    expect(calendar.byId(block.id), block);
    expect(find.text('Planned 2:00 PM – 3:30 PM (90m)'), findsOneWidget);
  }

  try {
    for (final complete in [false, true]) {
      await tester.ensureVisible(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      if (complete) {
        final completed = find.widgetWithText(CheckboxListTile, 'Completed');
        await tester.ensureVisible(completed);
        await tester.tap(completed);
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(nodes.byId(task.id)!.isDone, complete);
      expectPlanUnchanged();
      await refresh.syncFeed(feedId);
      expect(refresh.state.single.lastError, isNull);
      expect(refresh.state.single.lastSyncAt, isNotNull);
      await tester.pumpAndSettle();
      expect(nodes.byId(task.id)!.isDone, complete);
      expectPlanUnchanged();
    }
  } finally {
    await refresh.close();
    client.close();
  }
  expect(tester.takeException(), isNull);
}
