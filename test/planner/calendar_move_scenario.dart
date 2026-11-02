import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/planner/view/event_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Google extends Mock implements GoogleCalendarService {}

/// Drives the real editor and FeedCubit; Google returns only remote fields.
Future<void> verifyCalendarMove(
  WidgetTester tester,
  BuildContext context, {
  required String? source,
  required String? destination,
  bool legacy = false,
  bool createFails = false,
  bool golden = false,
}) async {
  final calendar = context.read<CalendarCubit>();
  final start = DateTime(2026, 11, 2, 9);
  final sessions = [
    TimeSession(
      id: 'first',
      start: start,
      end: start.add(const Duration(minutes: 10)),
    ),
    TimeSession(
      id: 'second',
      start: start.add(const Duration(minutes: 20)),
      end: start.add(const Duration(minutes: 30)),
    ),
  ];
  final base = PlannerEvent(
    id: 'original',
    subject: 'Recorded event',
    start: start,
    end: start.add(const Duration(hours: 1)),
    feedId: source,
    sourceUid: source == null ? null : 'remote-original',
    sessions: legacy ? const [] : sessions,
    actualStart: sessions.first.start,
    actualEnd: sessions.last.end,
    timerStartedAt: start.add(const Duration(minutes: 40)),
  );
  calendar.addEvent(base);
  final google = _Google();
  registerFallbackValue(base);
  final feeds = FeedCubit(
    calendarCubit: calendar,
    nodeCubit: context.read<NodeCubit>(),
    icalService: IcalService(),
    googleService: google,
    proxyBase: () => 'http://127.0.0.1:8000',
  );
  for (final id in ['a', 'b']) {
    feeds.addFeed(
      Feed(
        id: id,
        name: 'Calendar $id',
        url: '',
        kind: FeedKind.google,
        calendarId: id,
        createTasks: false,
      ),
    );
  }
  void expectRecording(PlannerEvent event) {
    expect(event.sessions, base.sessions);
    expect(event.recordedSessions, base.recordedSessions);
    expect(event.actualStart, base.actualStart);
    expect(event.actualEnd, base.actualEnd);
    expect(event.timerStartedAt, base.timerStartedAt);
    expect(event.taskId, isNull);
  }

  when(
    () => google.createEvent(
      calendarId: any(named: 'calendarId'),
      feedId: any(named: 'feedId'),
      event: any(named: 'event'),
    ),
  ).thenAnswer((call) async {
    expect(calendar.byId(base.id), isNotNull);
    final draft = call.namedArguments[#event] as PlannerEvent;
    expectRecording(draft);
    if (createFails) throw const GoogleCalendarException('Creation denied');
    return PlannerEvent(
      id: 'destination',
      subject: draft.subject,
      start: draft.start,
      end: draft.end,
      feedId: destination,
      sourceUid: 'new-remote',
    );
  });
  when(
    () => google.deleteEvent(
      calendarId: any(named: 'calendarId'),
      eventId: any(named: 'eventId'),
    ),
  ).thenAnswer((_) async {
    // The destination already contains every recording before remote deletion.
    expectRecording(calendar.state.singleWhere((e) => e.id != base.id));
  });
  final route = Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (routeContext) => BlocProvider.value(
        value: feeds,
        child: Scaffold(
          body: EventEditorForm(
            existing: base,
            title: 'Edit event',
            onFinished: () => Navigator.of(routeContext).pop(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final picker = find.byWidgetPredicate(
    (widget) =>
        widget is DropdownButtonFormField<String?> &&
        widget.decoration.labelText == 'Calendar',
  );
  await Scrollable.ensureVisible(tester.element(picker), alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.tap(picker);
  await tester.pumpAndSettle();
  await tester.tap(
    find
        .text(destination == null ? 'This device' : 'Calendar $destination')
        .last,
  );
  await tester.pumpAndSettle();
  if (golden) {
    await expectLater(
      find.byType(Scaffold).last,
      matchesGoldenFile('../goldens/calendar_move.selected_destination.png'),
    );
  }
  await tester.ensureVisible(find.text('Save'));
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
  if (createFails) {
    expect(calendar.byId(base.id), base);
    expect(calendar.state.where((e) => e.id != base.id), isEmpty);
    expect(find.text('Creation denied'), findsOneWidget);
    verifyNever(
      () => google.deleteEvent(
        calendarId: any(named: 'calendarId'),
        eventId: any(named: 'eventId'),
      ),
    );
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
  } else {
    expect(calendar.byId(base.id), isNull);
    final moved = calendar.state.singleWhere((e) => e.subject == base.subject);
    expect(moved.feedId, destination);
    expectRecording(moved);
    if (source != null) {
      verify(
        () =>
            google.deleteEvent(calendarId: source, eventId: 'remote-original'),
      ).called(1);
    }
  }
  await route;
  await feeds.close();
  for (final event in calendar.state.toList()) {
    calendar.deleteEvent(event.id);
  }
  expect(tester.takeException(), isNull);
}
