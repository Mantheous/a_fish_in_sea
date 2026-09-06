import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/task_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/planner/service/task_event_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

class MockClient extends Mock implements http.Client {}

class MockGoogleService extends Mock implements GoogleCalendarService {}

PlannerEvent _personal(String id, DateTime start) => PlannerEvent(
      id: id,
      subject: 'Event $id',
      start: start,
      end: start.add(const Duration(hours: 1)),
    );

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

  group('PlannerEvent task fields', () {
    test('defaults are not-a-task for old persisted json', () {
      final event = PlannerEvent.fromJson({
        'id': 'e1',
        'subject': 'Old',
        'start': DateTime(2026, 9, 4, 9).toIso8601String(),
        'end': DateTime(2026, 9, 4, 10).toIso8601String(),
      });
      expect(event.isTask, isFalse);
      expect(event.done, isFalse);
      expect(event.completedAt, isNull);
    });

    test('serialization round trip preserves task state', () {
      final cubit = CalendarCubit();
      final at = DateTime(2026, 9, 4, 9);
      cubit.addEvent(_personal('e1', at).copyWith(
        isTask: true,
        done: true,
        completedAt: at,
      ));
      final restored = cubit.fromJson(cubit.toJson(cubit.state));
      expect(restored, cubit.state);
      expect(restored!.single.isTask, isTrue);
      expect(restored.single.done, isTrue);
    });
  });

  group('CalendarCubit task completion', () {
    test('toggleDone ignores non-task events', () {
      final cubit = CalendarCubit();
      cubit.addEvent(_personal('e1', DateTime(2026, 9, 4, 9)));
      cubit.toggleDone('e1');
      expect(cubit.byId('e1')!.done, isFalse);
    });

    test('toggleDone sets and clears completedAt', () {
      final cubit = CalendarCubit();
      cubit.addEvent(
        _personal('e1', DateTime(2026, 9, 4, 9)).copyWith(isTask: true),
      );
      cubit.toggleDone('e1');
      expect(cubit.byId('e1')!.done, isTrue);
      expect(cubit.byId('e1')!.completedAt, isNotNull);
      cubit.toggleDone('e1');
      expect(cubit.byId('e1')!.done, isFalse);
      expect(cubit.byId('e1')!.completedAt, isNull);
    });

    test('setTaskLink and clearTaskLink round trip', () {
      final cubit = CalendarCubit();
      cubit.addEvent(_personal('e1', DateTime(2026, 9, 4, 9)));
      cubit.setTaskLink('e1', 'task:e1');
      expect(cubit.byId('e1')!.isTask, isTrue);
      expect(cubit.byId('e1')!.taskId, 'task:e1');
      cubit.clearTaskLink('e1');
      expect(cubit.byId('e1')!.isTask, isFalse);
      expect(cubit.byId('e1')!.taskId, isNull);
    });
  });

  group('isTaskCandidate', () {
    test('other feeds accept everything recent', () {
      const feed = Feed(id: 'f1', name: 'Misc', url: 'https://x/y.ics');
      final now = DateTime.now();
      expect(
        isTaskCandidate(
          _personal('e1', now.add(const Duration(days: 1))),
          feed,
          now,
        ),
        isTrue,
      );
      expect(
        isTaskCandidate(
          _personal('e2', now.subtract(const Duration(days: 30))),
          feed,
          now,
        ),
        isFalse,
      );
    });

    test('canvas only accepts assignment uids', () {
      const feed = Feed(
        id: 'c',
        name: 'Canvas',
        url: 'https://x/y.ics',
        kind: FeedKind.canvas,
      );
      final now = DateTime.now();
      PlannerEvent evt(String uid) => PlannerEvent(
            id: 'hw:c:$uid',
            subject: 'Thing',
            start: now.add(const Duration(days: 1)),
            end: now.add(const Duration(days: 1, hours: 1)),
            feedId: 'c',
            sourceUid: uid,
          );
      expect(isTaskCandidate(evt('event-assignment-1'), feed, now), isTrue);
      expect(isTaskCandidate(evt('event-2'), feed, now), isFalse);
    });
  });

  group('TaskEventLink', () {
    late CalendarCubit calendar;
    late TaskCubit tasks;

    setUp(() {
      UndoCubit();
      calendar = CalendarCubit();
      tasks = TaskCubit();
    });

    test('marking a personal event creates a linked task', () {
      calendar.addEvent(_personal('evt:1', DateTime(2026, 9, 4, 9)));
      TaskEventLink.markEventAsTask(calendar, tasks, 'evt:1');
      expect(calendar.byId('evt:1')!.isTask, isTrue);
      expect(tasks.state.length, 1);
      expect(tasks.state.single.calendarEventId, 'evt:1');
      expect(calendar.byId('evt:1')!.taskId, tasks.state.single.id);
    });

    test('toggling the event mirrors onto the task and back', () {
      calendar.addEvent(_personal('evt:1', DateTime(2026, 9, 4, 9)));
      TaskEventLink.markEventAsTask(calendar, tasks, 'evt:1');
      final taskId = tasks.state.single.id;
      TaskEventLink.toggleEventDone(calendar, tasks, 'evt:1');
      expect(calendar.byId('evt:1')!.done, isTrue);
      expect(tasks.byId(taskId)!.done, isTrue);
      TaskEventLink.toggleTaskDone(tasks, calendar, taskId);
      expect(tasks.byId(taskId)!.done, isFalse);
      expect(calendar.byId('evt:1')!.done, isFalse);
    });

    test('unmarking deletes the backing task but keeps the event', () {
      calendar.addEvent(_personal('evt:1', DateTime(2026, 9, 4, 9)));
      TaskEventLink.markEventAsTask(calendar, tasks, 'evt:1');
      TaskEventLink.unmarkEventAsTask(calendar, tasks, 'evt:1');
      expect(tasks.state, isEmpty);
      expect(calendar.byId('evt:1'), isNotNull);
      expect(calendar.byId('evt:1')!.isTask, isFalse);
    });

    test('toggling an imported homework task mirrors onto the event', () {
      final now = DateTime.now();
      const feed = Feed(id: 'f1', name: 'Class', url: 'https://x/y.ics');
      final event = PlannerEvent(
        id: 'hw:f1:a1',
        subject: 'Homework 1',
        start: now.add(const Duration(days: 2)),
        end: now.add(const Duration(days: 2, hours: 1)),
        feedId: 'f1',
        sourceUid: 'a1',
        isTask: true,
      );
      calendar.addEvent(event);
      tasks.importFromFeed([event], feed);
      TaskEventLink.toggleTaskDone(tasks, calendar, 'hw:f1:a1');
      expect(tasks.byId('hw:f1:a1')!.done, isTrue);
      expect(calendar.byId('hw:f1:a1')!.done, isTrue);
    });
  });

  group('Feed sync marks homework as tasks', () {
    late FeedCubit feedCubit;
    late CalendarCubit calendar;
    late TaskCubit tasks;
    late MockClient client;

    const ics = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:event-assignment-1
DTSTAMP:20260901T120000Z
DTSTART:20300101T090000Z
DTEND:20300101T091500Z
SUMMARY:Exit Quiz [STAT 230-002]
END:VEVENT
BEGIN:VEVENT
UID:event-2
DTSTAMP:20260901T120000Z
DTSTART:20300101T100000Z
DTEND:20300101T110000Z
SUMMARY:Lecture [STAT 230-002]
END:VEVENT
END:VCALENDAR
''';

    setUp(() {
      UndoCubit();
      client = MockClient();
      registerFallbackValue(Uri.parse('https://example.com/feed.ics'));
      when(() => client.get(any()))
          .thenAnswer((_) async => http.Response(ics, 200));
      calendar = CalendarCubit();
      tasks = TaskCubit();
      feedCubit = FeedCubit(
        calendarCubit: calendar,
        taskCubit: tasks,
        icalService: IcalService(client: client),
        googleService: MockGoogleService(),
        proxyBase: () => 'http://localhost:8000',
      );
    });

    test('canvas assignments sync as task-events, sessions do not', () async {
      feedCubit.addFeed(const Feed(
        id: 'canvas',
        name: 'Canvas',
        url: 'https://example.com/feed.ics',
        kind: FeedKind.canvas,
      ));
      await feedCubit.syncAll();
      final assignment =
          calendar.byId('hw:canvas:event-assignment-1')!;
      expect(assignment.isTask, isTrue);
      expect(assignment.classLabel, 'STAT 230-002');
      expect(calendar.byId('hw:canvas:event-2')!.isTask, isFalse);
      expect(tasks.byId('hw:canvas:event-assignment-1'), isNotNull);
    });

    test('completion survives a resync', () async {
      feedCubit.addFeed(const Feed(
        id: 'canvas',
        name: 'Canvas',
        url: 'https://example.com/feed.ics',
        kind: FeedKind.canvas,
      ));
      await feedCubit.syncAll();
      TaskEventLink.toggleEventDone(
        calendar,
        tasks,
        'hw:canvas:event-assignment-1',
      );
      await feedCubit.syncAll(force: true);
      expect(calendar.byId('hw:canvas:event-assignment-1')!.done, isTrue);
      expect(tasks.byId('hw:canvas:event-assignment-1')!.done, isTrue);
    });

    test('unmarked homework stays unmarked across resyncs', () async {
      feedCubit.addFeed(const Feed(
        id: 'canvas',
        name: 'Canvas',
        url: 'https://example.com/feed.ics',
        kind: FeedKind.canvas,
      ));
      await feedCubit.syncAll();
      TaskEventLink.unmarkEventAsTask(
        calendar,
        tasks,
        'hw:canvas:event-assignment-1',
      );
      await feedCubit.syncAll(force: true);
      expect(
        calendar.byId('hw:canvas:event-assignment-1')!.isTask,
        isFalse,
      );
      expect(tasks.byId('hw:canvas:event-assignment-1'), isNull);
    });
  });
}
