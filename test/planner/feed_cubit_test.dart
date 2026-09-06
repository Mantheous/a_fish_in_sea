import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/task_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

class MockClient extends Mock implements http.Client {}

class MockGoogleService extends Mock implements GoogleCalendarService {}

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
    late TaskCubit taskCubit;
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
      taskCubit = TaskCubit();
      feedCubit = FeedCubit(
        calendarCubit: calendarCubit,
        taskCubit: taskCubit,
        icalService: IcalService(client: client),
        googleService: googleService,
        proxyBase: () => 'http://localhost:8000',
      );
    });

    test('syncAll imports events and tasks', () async {
      feedCubit.addFeed(feed);
      await feedCubit.syncAll();
      expect(calendarCubit.state.length, 1);
      expect(calendarCubit.state.single.subject, 'Assignment A1');
      expect(taskCubit.state.length, 1);
      expect(taskCubit.state.single.sourceEventId, 'hw:f1:a1');
      expect(feedCubit.state.single.lastSyncAt, isNotNull);
      expect(feedCubit.state.single.lastError, isNull);
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
      expect(taskCubit.state, isEmpty);
    });

    test('removeFeed cascades and one undo restores everything', () async {
      feedCubit.addFeed(feed);
      await feedCubit.syncAll();
      feedCubit.removeFeed('f1');
      expect(feedCubit.state, isEmpty);
      expect(calendarCubit.state, isEmpty);
      expect(taskCubit.state, isEmpty);

      final undoCubit = UndoCubit.instance!;
      expect(undoCubit.canUndo, isTrue);
      undoCubit.undo();
      expect(feedCubit.state.single.id, 'f1');
      expect(calendarCubit.state.length, 1);
      expect(taskCubit.state.length, 1);
      expect(taskCubit.state.single.title, 'Assignment A1');
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
      expect(taskCubit.state, isEmpty);
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
        feedCubit.visibleTasks(taskCubit.state).map((t) => t.id),
        isEmpty,
      );

      feedCubit.updateFeed(feed.copyWith(enabled: true));
      expect(feedCubit.visibleEvents(calendarCubit.state).length, 1);
      expect(feedCubit.visibleTasks(taskCubit.state).length, 1);
    });
  });

  group('FeedCubit Google push', () {
    late FeedCubit feedCubit;
    late CalendarCubit calendarCubit;
    late TaskCubit taskCubit;
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
      taskCubit = TaskCubit();
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
        taskCubit: taskCubit,
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

    test('pushEventUpdate syncs the server copy locally', () async {
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
      verify(() => googleService.updateEvent(
            calendarId: 'cal1',
            feedId: 'gcal:cal1',
            eventId: 'ev1_20260910T123000Z',
            event: moved,
            instanceEdit: true,
          )).called(1);
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

    test('pushEventDelete removes the event via re-sync', () async {
      final original = googleEvent();
      calendarCubit.addEvent(original);
      when(() => googleService.deleteEvent(
            calendarId: any(named: 'calendarId'),
            eventId: any(named: 'eventId'),
          )).thenAnswer((_) async {});
      stubSync([]);

      final error = await feedCubit.pushEventDelete(original);

      expect(error, isNull);
      expect(calendarCubit.byId(original.id), isNull);
      verify(() => googleService.deleteEvent(
            calendarId: 'cal1',
            eventId: 'ev1',
          )).called(1);
    });

    test('pushEventCreate posts and picks up the synced event', () async {
      final draft = PlannerEvent(
        id: 'evt:tmp',
        subject: 'New standup',
        start: DateTime(2026, 9, 10, 12, 30),
        end: DateTime(2026, 9, 10, 13, 30),
        recurrenceRule: 'FREQ=WEEKLY;BYDAY=WE',
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
