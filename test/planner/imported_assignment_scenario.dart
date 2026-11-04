import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<void> verifyImportedAssignment(
  WidgetTester tester, {
  bool golden = false,
}) async {
  final context = tester.element(find.byType(CalendarPage));
  context.read<SettingsCubit>().setDayHours(8, 18);
  await tester.tap(find.text('Day'));
  await tester.pumpAndSettle();
  final start = DateTime(2030, 1, 1, 9);
  final controller = tester
      .widget<SfCalendar>(find.byType(SfCalendar))
      .controller!;
  controller.displayDate = start;
  controller.selectedDate = start;
  context.read<FeedCubit>().addFeed(
    const Feed(id: 'canvas', name: 'Canvas', url: '', kind: FeedKind.canvas),
  );
  final calendar = context.read<CalendarCubit>();
  final event = PlannerEvent(
    id: 'hw:canvas:assignment',
    subject: 'In-class Assignment: Family Food',
    start: start,
    end: start,
    feedId: 'canvas',
    sourceUid: 'assignment',
    isTask: true,
  );
  calendar.addEvent(event);
  final nodes = context.read<NodeCubit>();
  final due = DateTime(2030, 1, 3, 17);
  nodes.addNode(
    Node(
      id: event.id,
      title: event.subject,
      createdAt: start,
      sourceEventId: event.id,
      feedId: 'canvas',
      schedule: ScheduleFacet(due: due, start: start, end: start),
    ),
  );
  await tester.pumpAndSettle();
  final bounds = tester.getRect(find.byType(SfCalendar));
  for (final state in tester.stateList<ScrollableState>(
    find.descendant(
      of: find.byType(SfCalendar),
      matching: find.byType(Scrollable),
    ),
  )) {
    if (state.position.axis == Axis.vertical &&
        bounds.contains(tester.getRect(find.byWidget(state.widget)).center)) {
      state.position.jumpTo(0);
    }
  }
  await tester.pumpAndSettle();
  final tile = find.byKey(const ValueKey('tile:hw:canvas:assignment'));
  var rect = tester.getRect(tile);
  final gesture = await tester.startGesture(
    Offset(rect.left + 30, rect.center.dy),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveBy(const Offset(0, 65));
  await tester.pump(const Duration(milliseconds: 16));
  expect(tester.widget<Opacity>(tile).opacity, 0.35);
  await gesture.up();
  await tester.pumpAndSettle();
  final moved = calendar.byId(event.id)!;
  expect(moved.start.isAfter(start), isTrue);
  expect(moved.plannedDuration, const Duration(hours: 1));
  expect(moved.workTimeScheduled, isTrue);
  rect = tester.getRect(tile);
  await tester.tapAt(Offset(rect.left + 30, rect.center.dy));
  await tester.pumpAndSettle();
  final handle = find.bySemanticsLabel('Drag to change end time').last;
  await tester.drag(handle, const Offset(0, 40));
  await tester.pumpAndSettle();
  final resized = calendar.byId(event.id)!;
  expect(resized.end.isAfter(moved.end), isTrue);
  ScaffoldMessenger.of(context).clearSnackBars();
  await tester.pumpAndSettle();
  expect(find.text('Edit'), findsOneWidget);
  await tester.ensureVisible(find.text('Edit'));
  await tester.pumpAndSettle();
  if (golden) {
    await expectLater(
      find.byType(CalendarPage),
      matchesGoldenFile('../goldens/imported_assignment.png'),
    );
  }
  final completedAt = DateTime(2029, 12, 31, 16);
  final sessions = [
    TimeSession(
      id: 'previous-work',
      start: completedAt.subtract(const Duration(minutes: 20)),
      end: completedAt,
    ),
  ];
  calendar.updateEvent(
    resized.copyWith(done: true, completedAt: completedAt, sessions: sessions),
  );
  nodes.updateNode(
    nodes
        .byId(event.id)!
        .copyWith(
          status: NodeStatus.done,
          completedAt: completedAt,
          sessions: sessions,
        ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Edit'));
  await tester.pumpAndSettle();
  await _pickTime(tester, 'Start', '2', '15');
  await _pickTime(tester, 'End', '3', '45');
  await tester.ensureVisible(find.text('Save'));
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
  final editedStart = DateTime(2030, 1, 1, 14, 15);
  final editedEnd = DateTime(2030, 1, 1, 15, 45);
  void expectAligned() {
    final saved = calendar.byId(event.id)!;
    final task = nodes.byId(event.id)!;
    expect(saved.start, editedStart);
    expect(saved.end, editedEnd);
    expect(saved.feedId, 'canvas');
    expect(saved.workTimeScheduled, isTrue);
    expect(task.schedule!.start, saved.start);
    expect(task.schedule!.end, saved.end);
    expect(task.schedule!.due, due);
    expect(task.completedAt, completedAt);
    expect(task.isDone, isTrue);
    expect(task.sessions, sessions);
    expect(saved.done, isTrue);
    expect(saved.completedAt, completedAt);
    expect(saved.sessions, sessions);
    expect(find.text('Planned 2:15 PM – 3:45 PM (90m)'), findsOneWidget);
  }

  expectAligned();

  // Refresh through the real feed merge/import path with the original
  // source time. Keep the test offline in both widget and Patrol runs.
  final client = MockClient(
    (_) async => http.Response('''BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:assignment
DTSTAMP:20291101T120000Z
DTSTART:20300101T090000
DTEND:20300101T090000
SUMMARY:In-class Assignment: Family Food
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
  refresh.addFeed(
    const Feed(
      id: 'canvas',
      name: 'Canvas',
      url: 'https://example.com/class.ics',
      kind: FeedKind.canvas,
    ),
  );
  try {
    await refresh.syncFeed('canvas');
    expect(refresh.state.single.lastError, isNull);
    expect(refresh.state.single.lastSyncAt, isNotNull);
    await tester.pumpAndSettle();
    expectAligned();
  } finally {
    await refresh.close();
    client.close();
  }
  expect(tester.takeException(), isNull);
}

Future<void> _pickTime(
  WidgetTester tester,
  String label,
  String hour,
  String minute,
) async {
  final field = find.byWidgetPredicate(
    (widget) =>
        widget is InputDecorator && widget.decoration.labelText == label,
  );
  await Scrollable.ensureVisible(tester.element(field), alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: field, matching: find.byType(InkWell)));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Switch to text input mode'));
  await tester.pumpAndSettle();
  final inputs = find.descendant(
    of: find.byType(TimePickerDialog),
    matching: find.byType(TextField),
  );
  await tester.enterText(inputs.at(0), hour);
  await tester.enterText(inputs.at(1), minute);
  await tester.tap(find.text('PM'));
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}
