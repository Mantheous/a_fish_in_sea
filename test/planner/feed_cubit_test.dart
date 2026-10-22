import 'dart:async';

import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';import 'package:a_fish_in_sea/planner/bloc/assignment_estimates_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/model/assignment_estimate.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/model/task_assignee.dart';
import 'package:a_fish_in_sea/planner/service/canvas_service.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}
class MockClient extends Mock implements http.Client {}

class MockGoogleService extends Mock implements GoogleCalendarService {}

class MockCanvasService extends Mock implements CanvasService {}

const canvasIcs = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:event-assignment-42
DTSTAMP:20260901T120000Z
DTSTART:20300101T090000Z
DTEND:20300101T091500Z
SUMMARY:Homework 42 [STAT 230-002]
END:VEVENT
BEGIN:VEVENT
UID:event-assignment-43
DTSTAMP:20260901T120000Z
DTSTART:20300102T090000Z
DTEND:20300102T091500Z
SUMMARY:Homework 43 [STAT 230-002]
END:VEVENT
END:VCALENDAR
''';

const ics = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:a1
DTSTAMP:20260901T120000Z
DTSTART:20300101T090000Z
DTEND:20300101T091500Z
SUMMARY:Assignment A1
END:VEVENT
END:VCALENDAR
''';

void main() {
  late Storage storage;

  setUp(() {
    storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  final feed = const Feed(
    id: 'f1',
    name: 'REL 225',
    url: 'https://example.com/feed.ics',
  );

  group('FeedCubit sync', () {
    late FeedCubit feedCubit;
    late CalendarCubit calendarCubit;
    late NodeCubit nodeCubit;
    late AssignmentEstimatesCubit estimatesCubit;
    late MockClient client;
    late MockGoogleService googleService;

    setUp(() {
      UndoCubit();
      client = MockClient();
      googleService = MockGoogleService();
      registerFallbackValue(Uri.parse('https://example.com/feed.ics'));
      when(() => client.get(any()))
          .thenAnswer((_) async => http.Response(ics, 200));
      calendarCubit = CalendarCubit();
      nodeCubit = NodeCubit();
      estimatesCubit = AssignmentEstimatesCubit();
      feedCubit = FeedCubit(
        calendarCubit: calendarCubit,
        nodeCubit: nodeCubit,
        icalService: IcalService(client: client),
        googleService: googleService,
        proxyBase: () => 'http://localhost:8000',
        estimatesCubit: estimatesCubit,
      );
    });

    test('syncAll imports events and tasks', () async {
      feedCubit.addFeed(feed);
      await feedCubit.syncAll();
      expect(calendarCubit.state.length, 1);
      expect(calendarCubit.state.single.subject, 'Assignment A1');
      expect(nodeCubit.state.length, 1);
      expect(nodeCubit.state.single.sourceEventId, 'hw:f1:a1');
      expect(feedCubit.state.single.lastSyncAt, isNotNull);
      expect(feedCubit.state.single.lastError, isNull);
    });

    test('a multi-feed sync emits feed status once', () async {
      const second = Feed(
        id: 'f2',
        name: 'REL 226',
        url: 'https://example.com/feed2.ics',
      );
      feedCubit.addFeed(feed);
      feedCubit.addFeed(second);
      final emissions = <List<Feed>>[];
      final sub = feedCubit.stream.listen(emissions.add);
      await feedCubit.syncAll();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(emissions, hasLength(1));
      expect(feedCubit.state.every((f) => f.lastSyncAt != null), isTrue);
    });

    test('feed resync preserves local reminder and tags and undo history', () async {
      feedCubit.addFeed(feed.copyWith(createTasks: false));
      final undo = UndoCubit.instance!;
      expect(undo.canUndo, isTrue);

      await feedCubit.syncAll();
      final event = calendarCubit.state.single.copyWith(
        reminderMinutesBefore: 15,
        tagIds: const ['important'],
      );
      calendarCubit.replaceFeedEvents('f1', [event]);
      await feedCubit.syncFeed('f1');

      final synced = calendarCubit.state.single;
      expect(synced.reminderMinutesBefore, 15);
      expect(synced.tagIds, ['important']);
      expect(undo.canUndo, isTrue);
    });

    test('sync errors are recorded on the feed', () async {
      when(() => client.get(any()))
          .thenAnswer((_) async => http.Response('boom', 500));
      feedCubit.addFeed(feed);
      await feedCubit.syncAll();
      expect(feedCubit.state.single.lastError, isNotNull);
      expect(calendarCubit.state, isEmpty);
    });

    test('schedule feeds skip task import', () async {
      feedCubit.addFeed(feed.copyWith(createTasks: false));
      await feedCubit.syncAll();
      expect(calendarCubit.state.length, 1);
      expect(nodeCubit.state, isEmpty);
    });

    test('removeFeed cascades and one undo restores everything', () async {
      feedCubit.addFeed(feed);
      await feedCubit.syncAll();
      feedCubit.removeFeed('f1');
      expect(feedCubit.state, isEmpty);
      expect(calendarCubit.state, isEmpty);
      expect(nodeCubit.state, isEmpty);

      final undoCubit = UndoCubit.instance!;
      expect(undoCubit.canUndo, isTrue);
      undoCubit.undo();
      expect(feedCubit.state.single.id, 'f1');
      expect(calendarCubit.state.length, 1);
      expect(nodeCubit.state.length, 1);
      expect(nodeCubit.state.single.title, 'Assignment A1');
    });

    test('removeOrphanedClass clears leftovers of a vanished feed', () async {
      feedCubit.addFeed(feed);
      await feedCubit.syncAll();
      // Simulate the duplicate feed row disappearing (a class re-added while
      // sync was down, then the duplicate feed was dropped) while its
      // imported homework and events stayed behind.
      feedCubit.emit(const []);
      expect(feedCubit.state, isEmpty);
      expect(calendarCubit.state, isNotEmpty);
      expect(nodeCubit.state, isNotEmpty);

      feedCubit.removeOrphanedClass('f1');
      expect(calendarCubit.state, isEmpty);
      expect(nodeCubit.state, isEmpty);

      final undoCubit = UndoCubit.instance!;
      expect(undoCubit.canUndo, isTrue);
      undoCubit.undo();
      expect(calendarCubit.state.length, 1);
      expect(nodeCubit.state.single.sourceEventId, 'hw:f1:a1');
    });

    test('removeOrphanedClass ignores a class whose feed still exists',
        () async {
      feedCubit.addFeed(feed);
      await feedCubit.syncAll();

      feedCubit.removeOrphanedClass('f1');
      expect(calendarCubit.state.length, 1);
      expect(nodeCubit.state.length, 1);
      expect(feedCubit.state.single.id, 'f1');
    });

    test('removeFeed drops learned estimates and one undo restores them',
        () async {
      AssignmentTypeEffort effortFor(String feedId) => AssignmentTypeEffort(
            feedId: feedId,
            templateKey: 'quiz',
            samples: 3,
            totalMinutes: 90,
            minutes: const [30],
            startMinutes: const [1140],
            minMinutes: 30,
            maxMinutes: 30,
            updatedAt: DateTime(2026, 1, 1),
          );
      estimatesCubit.emit([effortFor('f1'), effortFor('f2')]);
      feedCubit.addFeed(feed);
      await feedCubit.syncAll();

      feedCubit.removeFeed('f1');
      expect(
        estimatesCubit.state.map((e) => e.feedId),
        ['f2'],
        reason: 'explicit class delete drops only that class',
      );

      UndoCubit.instance!.undo();
      expect(
        estimatesCubit.state.map((e) => e.feedId),
        ['f1', 'f2'],
        reason: 'undo brings the learned estimates back',
      );
    });

    test('google feeds sync via the google service', () async {
      final now = DateTime.now();
      final googleFeed = const Feed(
        id: 'gcal:cal1',
        name: 'Personal',
        url: '',
        kind: FeedKind.google,
        createTasks: false,
        calendarId: 'cal1',
      );
      final googleEvent = PlannerEvent(
        id: 'gcal:gcal:cal1:ev1',
        subject: 'Dentist',
        start: now.add(const Duration(days: 2)),
        end: now.add(const Duration(days: 2, hours: 1)),
        feedId: 'gcal:cal1',
        sourceUid: 'ev1',
      );
      when(() => googleService.fetchEvents(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
          )).thenAnswer((_) async => [googleEvent]);

      feedCubit.addFeed(googleFeed);
      await feedCubit.syncAll();

      expect(calendarCubit.state.single.subject, 'Dentist');
      expect(nodeCubit.state, isEmpty);
      expect(feedCubit.state.single.lastSyncAt, isNotNull);
      expect(feedCubit.state.single.lastError, isNull);
      verify(() => googleService.fetchEvents(
            calendarId: 'cal1',
            feedId: 'gcal:cal1',
          )).called(1);
    });

    test('google feed sync errors are recorded on the feed', () async {
      final googleFeed = const Feed(
        id: 'gcal:cal1',
        name: 'Personal',
        url: '',
        kind: FeedKind.google,
        createTasks: false,
        calendarId: 'cal1',
      );
      when(() => googleService.fetchEvents(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
          )).thenThrow(const GoogleCalendarException('not connected'));

      feedCubit.addFeed(googleFeed);
      await feedCubit.syncAll();

      expect(feedCubit.state.single.lastError, isNotNull);
      expect(calendarCubit.state, isEmpty);
    });

    test('disabled feeds are hidden but kept in cache', () async {
      feedCubit.addFeed(feed);
      await feedCubit.syncAll();
      expect(calendarCubit.state.length, 1);

      feedCubit.updateFeed(feed.copyWith(enabled: false));
      expect(calendarCubit.state.length, 1);
      expect(feedCubit.visibleEvents(calendarCubit.state), isEmpty);
      expect(
        feedCubit.visibleNodes(nodeCubit.state).map((n) => n.id),
        isEmpty,
      );

      feedCubit.updateFeed(feed.copyWith(enabled: true));
      expect(feedCubit.visibleEvents(calendarCubit.state).length, 1);
      expect(feedCubit.visibleNodes(nodeCubit.state).length, 1);
    });
  });

  group('FeedCubit Canvas completions', () {
    late FeedCubit feedCubit;
    late CalendarCubit calendarCubit;
    late NodeCubit nodeCubit;
    late MockClient client;
    late MockGoogleService googleService;
    late MockCanvasService canvasService;

    const canvasFeed = Feed(
      id: 'f1',
      name: 'STAT 230',
      url: 'https://byu.instructure.com/feeds/calendars/user_1.ics',
      kind: FeedKind.canvas,
    );

    setUp(() {
      UndoCubit();
      client = MockClient();
      googleService = MockGoogleService();
      canvasService = MockCanvasService();
      registerFallbackValue(Uri.parse('https://example.com/feed.ics'));
      when(() => client.get(any()))
          .thenAnswer((_) async => http.Response(canvasIcs, 200));
      when(() => canvasService.fetchSubmissions())
          .thenAnswer((_) async => const []);
      calendarCubit = CalendarCubit();
      nodeCubit = NodeCubit();
      feedCubit = FeedCubit(
        calendarCubit: calendarCubit,
        nodeCubit: nodeCubit,
        icalService: IcalService(client: client),
        googleService: googleService,
        proxyBase: () => 'http://localhost:8000',
        canvasService: canvasService,
      );
    });

    test('submitted homework completes on sync', () async {
      when(() => canvasService.fetchSubmissions()).thenAnswer((_) async =>
          const [CanvasSubmission(assignmentId: 42, submitted: true)]);
      feedCubit.addFeed(canvasFeed);
      await feedCubit.syncAll();

      expect(nodeCubit.state, hasLength(2));
      final done =
          nodeCubit.state.singleWhere((n) => n.title == 'Homework 42');
      expect(done.isDone, isTrue);
      expect(
        nodeCubit.state.singleWhere((n) => n.title == 'Homework 43').isOpen,
        isTrue,
      );
      expect(
        calendarCubit.byId('hw:f1:event-assignment-42')?.done,
        isTrue,
      );
      expect(
        calendarCubit.byId('hw:f1:event-assignment-43')?.done,
        isFalse,
      );
      expect(feedCubit.state.single.lastError, isNull);
    });

    test('graded without submission does not complete', () async {
      when(() => canvasService.fetchSubmissions()).thenAnswer((_) async =>
          const [CanvasSubmission(assignmentId: 42, graded: true)]);
      feedCubit.addFeed(canvasFeed);
      await feedCubit.syncAll();

      expect(nodeCubit.byId('hw:f1:event-assignment-42')?.isOpen, isTrue);
      expect(
        calendarCubit.byId('hw:f1:event-assignment-42')?.done,
        isFalse,
      );
    });

    test('failed nodes are left alone', () async {
      feedCubit.addFeed(canvasFeed);
      await feedCubit.syncAll();
      final id = 'hw:f1:event-assignment-42';
      nodeCubit.setStatus(id, NodeStatus.failed);

      when(() => canvasService.fetchSubmissions()).thenAnswer((_) async =>
          const [CanvasSubmission(assignmentId: 42, submitted: true)]);
      await feedCubit.syncFeed('f1');

      expect(nodeCubit.byId(id)?.status, NodeStatus.failed);
      expect(calendarCubit.byId(id)?.done, isFalse);
    });

    test('canvas failures never fail the feed sync', () async {
      when(() => canvasService.fetchSubmissions()).thenThrow(
        const CanvasException('Canvas account not connected',
            needsReconnect: true),
      );
      feedCubit.addFeed(canvasFeed);
      await feedCubit.syncAll();

      expect(calendarCubit.state, hasLength(2));
      expect(nodeCubit.state, hasLength(2));
      expect(feedCubit.state.single.lastSyncAt, isNotNull);
      expect(feedCubit.state.single.lastError, isNull);
    });
  });

  group('FeedCubit Google push', () {
    late FeedCubit feedCubit;
    late CalendarCubit calendarCubit;
    late NodeCubit nodeCubit;
    late MockGoogleService googleService;

    const googleFeed = Feed(
      id: 'gcal:cal1',
      name: 'Personal',
      url: '',
      kind: FeedKind.google,
      createTasks: false,
      calendarId: 'cal1',
    );

    PlannerEvent googleEvent() => PlannerEvent(
          id: 'gcal:gcal:cal1:ev1',
          subject: 'Dentist',
          start: DateTime(2026, 9, 10, 12, 30),
          end: DateTime(2026, 9, 10, 13, 30),
          feedId: 'gcal:cal1',
          sourceUid: 'ev1',
        );

    setUp(() {
      UndoCubit();
      googleService = MockGoogleService();
      calendarCubit = CalendarCubit();
      nodeCubit = NodeCubit();
      final mockClient = MockClient();
      registerFallbackValue(Uri.parse('https://example.com/feed.ics'));
      registerFallbackValue(PlannerEvent(
        id: 'fallback',
        subject: 'fallback',
        start: DateTime(2026, 1, 1),
        end: DateTime(2026, 1, 1, 1),
      ));
      when(() => mockClient.get(any()))
          .thenAnswer((_) async => http.Response(ics, 200));
      feedCubit = FeedCubit(
        calendarCubit: calendarCubit,
        nodeCubit: nodeCubit,
        icalService: IcalService(client: mockClient),
        googleService: googleService,
        proxyBase: () => 'http://localhost:8000',
      );
      feedCubit.addFeed(googleFeed);
    });

    test('local events are editable, other feeds are not', () {
      expect(
        feedCubit.isEventEditable(PlannerEvent(
          id: 'evt:1',
          subject: 'Local',
          start: DateTime(2026, 9, 10, 9),
          end: DateTime(2026, 9, 10, 10),
        )),
        isTrue,
      );
      expect(
        feedCubit.isEventEditable(PlannerEvent(
          id: 'evt:2',
          subject: 'Unknown feed',
          start: DateTime(2026, 9, 10, 9),
          end: DateTime(2026, 9, 10, 10),
          feedId: 'missing',
          sourceUid: 'x1',
        )),
        isFalse,
      );
    });

    test('recurring Google instances are remotely editable', () {
      expect(feedCubit.isRemoteEditable(googleEvent()), isTrue);
      expect(
        feedCubit.isRemoteEditable(PlannerEvent(
          id: 'gcal:gcal:cal1:ev1_20260910T123000Z',
          subject: 'Recurring instance',
          start: DateTime(2026, 9, 10, 12, 30),
          end: DateTime(2026, 9, 10, 13, 30),
          feedId: 'gcal:cal1',
          sourceUid: 'ev1_20260910T123000Z',
          seriesId: 'ev1',
          recurrenceRule: 'FREQ=WEEKLY;BYDAY=WE',
        )),
        isTrue,
      );
    });

    void stubSync(List<PlannerEvent> events) {
      when(() => googleService.fetchEvents(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
          )).thenAnswer((_) async => events);
    }

    test('pushEventUpdate applies the write response locally', () async {
      final original = googleEvent();
      calendarCubit.addEvent(original);
      final updated = original.copyWith(subject: 'Dentist (moved)');
      when(() => googleService.updateEvent(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
            eventId: any(named: 'eventId'),
            event: any(named: 'event'),
            instanceEdit: any(named: 'instanceEdit'),
          )).thenAnswer((_) async => updated);
      stubSync([updated]);

      final error = await feedCubit.pushEventUpdate(updated);

      expect(error, isNull);
      expect(calendarCubit.byId(original.id)?.subject, 'Dentist (moved)');
      verify(() => googleService.updateEvent(
            calendarId: 'cal1',
            feedId: 'gcal:cal1',
            eventId: 'ev1',
            event: updated,
            instanceEdit: false,
          )).called(1);
      // The save path must not wait on a full feed refetch.
      verifyNever(() => googleService.fetchEvents(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
          ));
    });

    test('pushEventUpdate keeps local-only fields off the network', () async {
      const assignees = [TaskAssignee(id: 'people/1', displayName: 'Amy')];
      final original = googleEvent();
      calendarCubit.addEvent(original);
      final updated = original.copyWith(
        subject: 'Dentist (moved)',
        assignees: assignees,
        reminderMinutesBefore: 15,
        isTask: true,
      );
      when(() => googleService.updateEvent(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
            eventId: any(named: 'eventId'),
            event: any(named: 'event'),
            instanceEdit: any(named: 'instanceEdit'),
          )).thenAnswer((_) async => updated.copyWith(
                assignees: const [],
                clearReminder: true,
                isTask: false,
              ));

      await feedCubit.pushEventUpdate(updated);

      final saved = calendarCubit.byId(original.id)!;
      expect(saved.assignees, assignees);
      expect(saved.reminderMinutesBefore, 15);
      expect(saved.isTask, isTrue);
    });

    test('resync preserves reminders and tags on task-marked events',
        () async {
      final fresh = googleEvent();
      stubSync([fresh]);
      await feedCubit.syncFeed(googleFeed.id);
      calendarCubit.updateEvent(
        calendarCubit.byId(fresh.id)!.copyWith(
          isTask: true,
          tagIds: const ['tag-focus'],
          reminderMinutesBefore: 30,
        ),
      );
      stubSync([fresh]);
      await feedCubit.syncFeed(googleFeed.id);
      final after = calendarCubit.byId(fresh.id)!;
      expect(after.isTask, isTrue);
      expect(after.tagIds, ['tag-focus']);
      expect(after.reminderMinutesBefore, 30);
    });

    test('google resync preserves local assignees', () async {
      const assignees = [TaskAssignee(id: 'people/1', displayName: 'Amy')];
      calendarCubit.addEvent(googleEvent().copyWith(assignees: assignees));
      // Fresh from the server: Google never stores assignees.
      stubSync([googleEvent()]);
      await feedCubit.syncFeed(googleFeed.id);
      expect(
        calendarCubit.byId('gcal:gcal:cal1:ev1')?.assignees,
        assignees,
      );
    });

    test('pushEventUpdate patches the instance for occurrences', () async {
      final instance = PlannerEvent(
        id: 'gcal:gcal:cal1:ev1_20260910T123000Z',
        subject: 'Standup',
        start: DateTime(2026, 9, 10, 12, 30),
        end: DateTime(2026, 9, 10, 13, 30),
        feedId: 'gcal:cal1',
        sourceUid: 'ev1_20260910T123000Z',
        seriesId: 'ev1',
        recurrenceRule: 'FREQ=WEEKLY;BYDAY=WE',
      );
      final moved = instance.copyWith(
        start: DateTime(2026, 9, 10, 14, 30),
        end: DateTime(2026, 9, 10, 15, 30),
      );
      when(() => googleService.updateEvent(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
            eventId: any(named: 'eventId'),
            event: any(named: 'event'),
            instanceEdit: any(named: 'instanceEdit'),
          )).thenAnswer((_) async => moved);
      stubSync([moved]);

      final error = await feedCubit.pushEventUpdate(moved);

      expect(error, isNull);
      expect(calendarCubit.byId(instance.id)?.start, moved.start);
      verify(() => googleService.updateEvent(
            calendarId: 'cal1',
            feedId: 'gcal:cal1',
            eventId: 'ev1_20260910T123000Z',
            event: moved,
            instanceEdit: true,
          )).called(1);
      verifyNever(() => googleService.fetchEvents(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
          ));
    });

    test('pushEventUpdate patches the master for series edits', () async {
      final master = PlannerEvent(
        id: 'gcal:gcal:cal1:ev1',
        subject: 'Standup',
        start: DateTime(2026, 9, 2, 12, 30),
        end: DateTime(2026, 9, 2, 13, 30),
        feedId: 'gcal:cal1',
        sourceUid: 'ev1',
        seriesId: 'ev1',
        recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO,WE,FR',
      );
      when(() => googleService.updateEvent(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
            eventId: any(named: 'eventId'),
            event: any(named: 'event'),
            instanceEdit: any(named: 'instanceEdit'),
          )).thenAnswer((_) async => master);
      stubSync([master]);

      final error =
          await feedCubit.pushEventUpdate(master, series: true);

      expect(error, isNull);
      verify(() => googleService.updateEvent(
            calendarId: 'cal1',
            feedId: 'gcal:cal1',
            eventId: 'ev1',
            event: master,
            instanceEdit: false,
          )).called(1);
      // Series writes still refetch: one write reshapes every occurrence.
      verify(() => googleService.fetchEvents(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
          )).called(1);
    });

    test('pushEventUpdate returns the error and keeps local state', () async {
      final original = googleEvent();
      calendarCubit.addEvent(original);
      when(() => googleService.updateEvent(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
            eventId: any(named: 'eventId'),
            event: any(named: 'event'),
            instanceEdit: any(named: 'instanceEdit'),
          )).thenThrow(const GoogleCalendarException('denied'));

      final error =
          await feedCubit.pushEventUpdate(original.copyWith(subject: 'X'));

      expect(error, 'denied');
      expect(calendarCubit.byId(original.id)?.subject, 'Dentist');
      verifyNever(() => googleService.fetchEvents(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
          ));
    });

    test('a write during an in-flight sync is reconciled after it', () async {
      final original = googleEvent();
      calendarCubit.addEvent(original);
      final updated = original.copyWith(subject: 'Dentist (moved)');
      final firstFetch = Completer<List<PlannerEvent>>();
      final secondFetch = Completer<List<PlannerEvent>>();
      var fetches = 0;
      when(() => googleService.fetchEvents(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
          )).thenAnswer((_) {
        fetches++;
        return fetches == 1 ? firstFetch.future : secondFetch.future;
      });
      when(() => googleService.updateEvent(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
            eventId: any(named: 'eventId'),
            event: any(named: 'event'),
            instanceEdit: any(named: 'instanceEdit'),
          )).thenAnswer((_) async => updated);

      final sync = feedCubit.syncFeed(googleFeed.id);
      await pumpEventQueue();
      expect(fetches, 1, reason: 'the pre-write fetch is in flight');

      final error = await feedCubit.pushEventUpdate(updated);
      expect(error, isNull);
      expect(calendarCubit.byId(original.id)?.subject, 'Dentist (moved)');

      // The stale snapshot from before the write lands after the write...
      firstFetch.complete([original]);
      await sync;
      await pumpEventQueue();
      expect(fetches, 2, reason: 'a reconcile pass was queued');
      secondFetch.complete([updated]);
      await pumpEventQueue();

      expect(calendarCubit.byId(original.id)?.subject, 'Dentist (moved)');
    });

    test('recurring create keeps the refetch', () async {
      final draft = PlannerEvent(
        id: 'evt:tmp',
        subject: 'New standup',
        start: DateTime(2026, 9, 10, 12, 30),
        end: DateTime(2026, 9, 10, 13, 30),
        recurrenceRule: 'FREQ=WEEKLY;BYDAY=WE',
      );
      final created = googleEvent().copyWith(
        subject: 'New standup',
        recurrenceRule: 'FREQ=WEEKLY;BYDAY=WE',
      );
      when(() => googleService.createEvent(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
            event: any(named: 'event'),
          )).thenAnswer((_) async => created);
      stubSync([created]);

      final result = await feedCubit.pushEventCreate(
        feed: googleFeed,
        event: draft,
      );

      expect(result.error, isNull);
      // Google expands recurring creates into instance rows; the refetch
      // is what makes local state match every later resync.
      verify(() => googleService.fetchEvents(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
          )).called(1);
    });

    test('pushEventDelete removes the event without a refetch', () async {
      final original = googleEvent();
      calendarCubit.addEvent(original);
      when(() => googleService.deleteEvent(
            calendarId: any(named: 'calendarId'),
            eventId: any(named: 'eventId'),
          )).thenAnswer((_) async {});

      final error = await feedCubit.pushEventDelete(original);

      expect(error, isNull);
      expect(calendarCubit.byId(original.id), isNull);
      verify(() => googleService.deleteEvent(
            calendarId: 'cal1',
            eventId: 'ev1',
          )).called(1);
      verifyNever(() => googleService.fetchEvents(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
          ));
    });

    test('pushEventDelete(series) drops every local occurrence', () async {
      final master = PlannerEvent(
        id: 'gcal:gcal:cal1:ev1',
        subject: 'Standup',
        start: DateTime(2026, 9, 2, 12, 30),
        end: DateTime(2026, 9, 2, 13, 30),
        feedId: 'gcal:cal1',
        sourceUid: 'ev1',
        seriesId: 'ev1',
        recurrenceRule: 'FREQ=WEEKLY;BYDAY=WE',
      );
      final instance = PlannerEvent(
        id: 'gcal:gcal:cal1:ev1_20260910T123000Z',
        subject: 'Standup',
        start: DateTime(2026, 9, 10, 12, 30),
        end: DateTime(2026, 9, 10, 13, 30),
        feedId: 'gcal:cal1',
        sourceUid: 'ev1_20260910T123000Z',
        seriesId: 'ev1',
      );
      calendarCubit.addEvent(master);
      calendarCubit.addEvent(instance);
      when(() => googleService.deleteEvent(
            calendarId: any(named: 'calendarId'),
            eventId: any(named: 'eventId'),
          )).thenAnswer((_) async {});

      final error = await feedCubit.pushEventDelete(instance, series: true);

      expect(error, isNull);
      expect(calendarCubit.byId(master.id), isNull);
      expect(calendarCubit.byId(instance.id), isNull);
      verify(() => googleService.deleteEvent(
            calendarId: 'cal1',
            eventId: 'ev1',
          )).called(1);
      verifyNever(() => googleService.fetchEvents(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
          ));
    });

    test('pushEventCreate posts and picks up the synced event', () async {
      final draft = PlannerEvent(
        id: 'evt:tmp',
        subject: 'New standup',
        start: DateTime(2026, 9, 10, 12, 30),
        end: DateTime(2026, 9, 10, 13, 30),
      );
      final created = googleEvent().copyWith(subject: 'New standup');
      when(() => googleService.createEvent(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
            event: any(named: 'event'),
          )).thenAnswer((_) async => created);
      stubSync([created]);

      final result = await feedCubit.pushEventCreate(
        feed: googleFeed,
        event: draft,
      );

      expect(result.error, isNull);
      expect(result.created?.id, created.id);
      expect(calendarCubit.byId(created.id)?.subject, 'New standup');
      verify(() => googleService.createEvent(
            calendarId: 'cal1',
            feedId: 'gcal:cal1',
            event: draft,
          )).called(1);
      // The created event is applied from the write response, not a
      // full refetch of the calendar.
      verifyNever(() => googleService.fetchEvents(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
          ));
    });

    test('manually marked Google events keep isTask across resync',
        () async {
      final fresh = googleEvent();
      stubSync([fresh]);
      await feedCubit.syncFeed(googleFeed.id);
      expect(calendarCubit.byId(fresh.id)?.isTask, isFalse);

      // User edits the event and marks it as a task (event editor path).
      final marked =
          calendarCubit.byId(fresh.id)!.copyWith(isTask: true);
      calendarCubit.updateEvent(marked);
      nodeCubit.ensureNodeForFeedEvent(marked);
      expect(nodeCubit.nodesForEventId(fresh.id), isNotEmpty);

      // Next sync returns the same server event without the local flag.
      stubSync([fresh]);
      await feedCubit.syncFeed(googleFeed.id);

      expect(calendarCubit.byId(fresh.id)?.isTask, isTrue);
      expect(nodeCubit.nodesForEventId(fresh.id), isNotEmpty);
    });

    test('backing node heals a lost calendar flag on resync', () async {
      final fresh = googleEvent();
      stubSync([fresh]);
      await feedCubit.syncFeed(googleFeed.id);

      final marked =
          calendarCubit.byId(fresh.id)!.copyWith(isTask: true);
      calendarCubit.updateEvent(marked);
      nodeCubit.ensureNodeForFeedEvent(marked);

      // Simulate the local-only flag getting lost (fresh storage /
      // hydrate race) while the backing node survives.
      calendarCubit.updateEvent(fresh.copyWith(isTask: false));
      expect(calendarCubit.byId(fresh.id)?.isTask, isFalse);

      stubSync([fresh]);
      await feedCubit.syncFeed(googleFeed.id);

      expect(calendarCubit.byId(fresh.id)?.isTask, isTrue);
    });

    test('fetchSeriesMaster returns the master event', () async {
      final instance = PlannerEvent(
        id: 'gcal:gcal:cal1:ev1_20260910T123000Z',
        subject: 'Standup',
        start: DateTime(2026, 9, 10, 12, 30),
        end: DateTime(2026, 9, 10, 13, 30),
        feedId: 'gcal:cal1',
        sourceUid: 'ev1_20260910T123000Z',
        seriesId: 'ev1',
        recurrenceRule: 'FREQ=WEEKLY;BYDAY=WE',
      );
      final master = PlannerEvent(
        id: 'gcal:gcal:cal1:ev1',
        subject: 'Standup',
        start: DateTime(2026, 9, 2, 12, 30),
        end: DateTime(2026, 9, 2, 13, 30),
        feedId: 'gcal:cal1',
        sourceUid: 'ev1',
        seriesId: 'ev1',
        recurrenceRule: 'FREQ=WEEKLY;BYDAY=WE',
      );
      when(() => googleService.fetchEvent(
            calendarId: any(named: 'calendarId'),
            feedId: any(named: 'feedId'),
            eventId: any(named: 'eventId'),
          )).thenAnswer((_) async => master);

      final fetched = await feedCubit.fetchSeriesMaster(instance);

      expect(fetched?.sourceUid, 'ev1');
      expect(fetched?.recurrenceRule, 'FREQ=WEEKLY;BYDAY=WE');
      verify(() => googleService.fetchEvent(
            calendarId: 'cal1',
            feedId: 'gcal:cal1',
            eventId: 'ev1',
          )).called(1);
    });
  });
}
