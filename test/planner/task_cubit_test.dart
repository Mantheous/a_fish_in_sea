import 'package:a_fish_in_sea/planner/bloc/task_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/model/task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

PlannerEvent _event(String uid, DateTime start) => PlannerEvent(
      id: 'hw:f1:$uid',
      subject: 'Assignment $uid',
      start: start,
      end: start.add(const Duration(minutes: 15)),
      feedId: 'f1',
      sourceUid: uid,
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

  group('TaskCubit', () {
    test('initial state is empty', () {
      final cubit = TaskCubit();
      expect(cubit.state, isEmpty);
    });

    test('addTask adds', () {
      final cubit = TaskCubit();
      cubit.addTask(const Task(id: 't1', title: 'Read'));
      expect(cubit.state.length, 1);
      expect(cubit.state.single.title, 'Read');
    });

    test('toggleDone sets and clears completedAt', () {
      final cubit = TaskCubit();
      cubit.addTask(const Task(id: 't1', title: 'Read'));
      cubit.toggleDone('t1');
      expect(cubit.state.single.done, isTrue);
      expect(cubit.state.single.completedAt, isNotNull);
      cubit.toggleDone('t1');
      expect(cubit.state.single.done, isFalse);
      expect(cubit.state.single.completedAt, isNull);
    });

    test('updateTask and deleteTask work by id', () {
      final cubit = TaskCubit();
      cubit.addTask(const Task(id: 't1', title: 'Read'));
      cubit.updateTask(const Task(id: 't1', title: 'Read chapters 1-2'));
      expect(cubit.state.single.title, 'Read chapters 1-2');
      cubit.deleteTask('t1');
      expect(cubit.state, isEmpty);
    });

    test('openTasks sorts incomplete first by due date', () {
      final cubit = TaskCubit();
      final now = DateTime.now();
      cubit.addTask(Task(
        id: 'a',
        title: 'due later',
        due: now.add(const Duration(days: 2)),
      ));
      cubit.addTask(Task(
        id: 'b',
        title: 'due sooner',
        due: now.add(const Duration(days: 1)),
      ));
      cubit.addTask(const Task(id: 'c', title: 'no due date'));
      cubit.addTask(const Task(id: 'd', title: 'already done', done: true));
      final titles =
          cubit.openTasks.map((t) => t.id).toList();
      expect(titles, ['b', 'a', 'c', 'd']);
    });

    test('importFromFeed creates tasks for recent and upcoming events', () {
      final cubit = TaskCubit();
      final now = DateTime.now();
      final feed = const Feed(id: 'f1', name: 'REL 225', url: 'https://example.com/feed.ics');
      final events = [
        _event('e1', now.add(const Duration(days: 3))),
        _event('e2', now.subtract(const Duration(days: 2))),
        _event('e3', now.subtract(const Duration(days: 20))),
      ];
      cubit.importFromFeed(events, feed);
      expect(cubit.state.length, 2);
      expect(cubit.state.every((t) => t.isImported), isTrue);
      expect(cubit.state.every((t) => t.classId == 'f1'), isTrue);
    });

    test('importFromFeed is idempotent across resyncs', () {
      final cubit = TaskCubit();
      final now = DateTime.now();
      final feed = const Feed(id: 'f1', name: 'REL 225', url: 'https://example.com/feed.ics');
      final events = [_event('e1', now.add(const Duration(days: 3)))];
      cubit.importFromFeed(events, feed);
      cubit.importFromFeed(events, feed);
      expect(cubit.state.length, 1);
    });

    test('completion survives a resync', () {
      final cubit = TaskCubit();
      final now = DateTime.now();
      final feed = const Feed(id: 'f1', name: 'REL 225', url: 'https://example.com/feed.ics');
      final events = [_event('e1', now.add(const Duration(days: 3)))];
      cubit.importFromFeed(events, feed);
      cubit.toggleDone('hw:f1:e1');
      cubit.importFromFeed(events, feed);
      expect(cubit.state.length, 1);
      expect(cubit.state.single.done, isTrue);
    });

    test('removeImportedTasksFor keeps manual tasks', () {
      final cubit = TaskCubit();
      final now = DateTime.now();
      final feed = const Feed(id: 'f1', name: 'REL 225', url: 'https://example.com/feed.ics');
      cubit.importFromFeed([_event('e1', now.add(const Duration(days: 3)))],
          feed);
      cubit.addTask(const Task(id: 'manual', title: 'Buy milk'));
      cubit.removeImportedTasksFor('f1');
      expect(cubit.state.length, 1);
      expect(cubit.state.single.id, 'manual');
    });

    test('canvas feeds only import assignment events, with classLabel', () {
      final cubit = TaskCubit();
      final now = DateTime.now();
      final feed = const Feed(
        id: 'canvas',
        name: 'Canvas',
        url: 'https://byu.instructure.com/feeds/calendars/user_x.ics',
        kind: FeedKind.canvas,
      );
      final assignment = _event(
        'event-assignment-1',
        now.add(const Duration(days: 3)),
      ).copyWith(subject: 'Exit Quiz', clearNotes: true);
      final classSession = _event(
        'event-2',
        now.add(const Duration(days: 3)),
      );
      cubit.importFromFeed([assignment, classSession], feed);
      expect(cubit.state.length, 1);
      expect(cubit.state.single.id, 'hw:f1:event-assignment-1');
      expect(cubit.state.single.classLabel, isNull);
    });

    test('canvas tasks carry the parsed course label', () {
      final cubit = TaskCubit();
      final now = DateTime.now();
      final feed = const Feed(
        id: 'canvas',
        name: 'Canvas',
        url: 'https://byu.instructure.com/feeds/calendars/user_x.ics',
        kind: FeedKind.canvas,
      );
      final event = PlannerEvent(
        id: 'hw:canvas:event-assignment-2',
        subject: 'Exit Quiz',
        start: now.add(const Duration(days: 3)),
        end: now.add(const Duration(days: 3, minutes: 15)),
        feedId: feed.id,
        sourceUid: 'event-assignment-2',
        classLabel: 'STAT 230-002',
      );
      cubit.importFromFeed([event], feed);
      expect(cubit.state.single.classLabel, 'STAT 230-002');
      expect(cubit.state.single.classId, 'canvas');
    });

    test('learningSuite feeds only import assignment-like events', () {
      final cubit = TaskCubit();
      final now = DateTime.now();
      final feed = const Feed(
        id: 'ls',
        name: 'Civ Lit',
        url: 'https://learningsuite.byu.edu/iCalFeed/ical.php?courseID=x',
        kind: FeedKind.learningSuite,
      );
      PlannerEvent lsEvent(String uid, String subject) => PlannerEvent(
            id: 'hw:ls:$uid',
            subject: subject,
            start: now.add(const Duration(days: 3)),
            end: now.add(const Duration(days: 3, minutes: 15)),
            feedId: 'ls',
            sourceUid: uid,
          );
      cubit.importFromFeed(
        [
          lsEvent('a', 'Record Total Reading Points out of 34 pages'),
          lsEvent('b', 'Take Midterm 2 on Learning Suite'),
          lsEvent('c', 'England'),
          lsEvent('d', 'Feminist Criticism'),
          lsEvent('e', 'Game Day: Debate #1 and Vote #1'),
        ],
        feed,
      );
      expect(
        cubit.state.map((t) => t.title),
        [
          'Record Total Reading Points out of 34 pages',
          'Take Midterm 2 on Learning Suite',
        ],
      );
    });

    test('learningSuite resync prunes open topic tasks, keeps done ones', () {
      final cubit = TaskCubit();
      final feed = const Feed(
        id: 'ls',
        name: 'Civ Lit',
        url: 'https://learningsuite.byu.edu/iCalFeed/ical.php?courseID=x',
        kind: FeedKind.learningSuite,
      );
      cubit.addTask(const Task(
        id: 'hw:ls:topic',
        title: 'England',
        sourceEventId: 'hw:ls:topic',
        classId: 'ls',
      ));
      cubit.addTask(const Task(
        id: 'hw:ls:done-topic',
        title: 'Russia',
        sourceEventId: 'hw:ls:done-topic',
        classId: 'ls',
        done: true,
      ));
      cubit.addTask(const Task(
        id: 'hw:ls:hw',
        title: 'Read chapters 1-2',
        sourceEventId: 'hw:ls:hw',
        classId: 'ls',
      ));
      cubit.importFromFeed(const [], feed);
      expect(
        cubit.state.map((t) => t.id),
        ['hw:ls:done-topic', 'hw:ls:hw'],
      );
    });

    test('serialization round trip', () {
      final cubit = TaskCubit();
      final now = DateTime.now();
      final feed = const Feed(id: 'f1', name: 'REL 225', url: 'https://example.com/feed.ics');
      cubit.importFromFeed([_event('e1', now.add(const Duration(days: 3)))],
          feed);
      final restored = cubit.fromJson(cubit.toJson(cubit.state));
      expect(restored, cubit.state);
    });
  });
}
