import 'package:a_fish_in_sea/planner/bloc/task_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/model/task.dart';
import 'package:a_fish_in_sea/planner/model/task_assignee.dart';
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

    test('learningSuite feeds only import gradebook items, not schedule text',
        () {
      final cubit = TaskCubit();
      final now = DateTime.now();
      final feed = const Feed(
        id: 'ls',
        name: 'Civ Lit',
        url: 'https://learningsuite.byu.edu/iCalFeed/ical.php?courseID=x',
        kind: FeedKind.learningSuite,
      );
      PlannerEvent lsEvent(
        String uid,
        String subject, {
        String? notes,
        DateTime? start,
        DateTime? end,
      }) =>
          PlannerEvent(
            id: 'hw:ls:$uid',
            subject: subject,
            notes: notes,
            start: start ?? now.add(const Duration(days: 3)),
            end: end ?? now.add(const Duration(days: 3, minutes: 15)),
            allDay: true,
            feedId: 'ls',
            sourceUid: uid,
          );
      final windowStart = now.subtract(const Duration(days: 30));
      final windowEnd = now.add(const Duration(days: 30));
      cubit.importFromFeed(
        [
          // Open..due window opened over a month ago: still imported.
          lsEvent(
            'a',
            'Unit 1 Reading Points',
            notes: 'Please enter how many pages you read for each reading.',
            start: windowStart,
            end: windowEnd,
          ),
          // Written homework: title differs from the instructions.
          lsEvent(
            'b',
            'Homework 6 -- Parse Trees and Ambiguity',
            notes: 'Complete the following 4 problems. Submit a photo.',
          ),
          // Due-date-only gradebook item with no instructions.
          lsEvent('c', 'Homework Section 31'),
          // Schedule/commentary: notes echo the subject.
          lsEvent('d', 'England', notes: 'England'),
          lsEvent(
            'e',
            'Post 2-3 times on DD and quote during Game Day. Quote Points should be at 42 by the end o',
            notes:
                'Post 2-3 times on DD and quote during Game Day. Quote Points should be at 42 by the end of today.',
          ),
          lsEvent(
            'f',
            'HW 10b typically takes more time than the previous homework assignments.',
            notes:
                'HW 10b typically takes more time than the previous homework assignments. It is a good idea to do HW 10a first.',
          ),
          // Blank schedule line (parsed as Untitled).
          lsEvent('g', 'Untitled', notes: ' '),
          // Long-expired window: excluded.
          lsEvent(
            'h',
            'Unit 1 Reading Points',
            notes: 'Please enter how many pages you read for each reading.',
            start: now.subtract(const Duration(days: 60)),
            end: now.subtract(const Duration(days: 30)),
          ),
        ],
        feed,
      );
      expect(
        cubit.state.map((t) => t.title),
        [
          'Unit 1 Reading Points',
          'Homework 6 -- Parse Trees and Ambiguity',
          'Homework Section 31',
        ],
      );
      // Window tasks are due at the end of the window, plannable from open.
      final window = cubit.state.firstWhere(
        (t) => t.title == 'Unit 1 Reading Points',
      );
      expect(window.due, windowEnd);
      expect(window.plannedStart, windowStart);
      expect(window.plannedEnd, windowEnd);
      // Single-date items are due on their date.
      final single = cubit.state.firstWhere(
        (t) => t.title == 'Homework Section 31',
      );
      expect(single.due, isNotNull);
    });

    test('learningSuite filter ignores title keywords, uses structure', () {
      final cubit = TaskCubit();
      final now = DateTime.now();
      final feed = const Feed(
        id: 'ls',
        name: 'MATH 290',
        url: 'https://learningsuite.byu.edu/iCalFeed/ical.php?courseID=x',
        kind: FeedKind.learningSuite,
      );
      PlannerEvent lsEvent(String uid, String subject, {String? notes}) =>
          PlannerEvent(
            id: 'hw:ls:$uid',
            subject: subject,
            notes: notes,
            start: now.add(const Duration(days: 3)),
            end: now.add(const Duration(days: 3, minutes: 15)),
            allDay: true,
            feedId: 'ls',
            sourceUid: uid,
          );
      // Copied from real feeds: topic titles containing old keyword
      // substrings ("exam" in Examples, "post" in Postmodern) stay out
      // when the notes just echo them; real items stay in even when the
      // title has no action verb.
      cubit.importFromFeed(
        [
          lsEvent(
            'a',
            'Section 30: More Examples of Countable Sets',
            notes: 'Section 30: More Examples of Countable Sets',
          ),
          lsEvent(
            'b',
            'Postmodern Criticism',
            notes: 'Postmodern Criticism',
          ),
          lsEvent(
            'c',
            'Game Day: Presentations',
            notes: 'Game Day: Presentations',
          ),
          lsEvent(
            'd',
            'Unit 3 Quote Point Tracker',
            notes: 'Enter each day\u2019s points under Exams, then SUBMIT.',
          ),
          lsEvent(
            'e',
            'Th Sept 5 Attendance Writing',
            notes: 'Submit a paragraph about today\u2019s discussion.',
          ),
        ],
        feed,
      );
      expect(
        cubit.state.map((t) => t.title),
        [
          'Unit 3 Quote Point Tracker',
          'Th Sept 5 Attendance Writing',
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
        notes: 'England',
        sourceEventId: 'hw:ls:topic',
        classId: 'ls',
      ));
      cubit.addTask(const Task(
        id: 'hw:ls:done-topic',
        title: 'Russia',
        notes: 'Russia',
        sourceEventId: 'hw:ls:done-topic',
        classId: 'ls',
        done: true,
      ));
      cubit.addTask(const Task(
        id: 'hw:ls:hw',
        title: 'Homework 6 -- Parse Trees and Ambiguity',
        notes: 'Complete the following 4 problems. Submit a photo.',
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

    test('assignees survive copyWith paths that sync event fields', () {
      final cubit = TaskCubit();
      const assignees = [
        TaskAssignee(id: 'people/1', displayName: 'Amy'),
      ];
      cubit.addTask(const Task(
        id: 't1',
        title: 'Visit',
        assignees: assignees,
      ));
      cubit.updateTask(cubit.byId('t1')!.copyWith(title: 'Visit Amy'));
      expect(cubit.byId('t1')!.assignees, assignees);
      cubit.toggleDone('t1');
      cubit.toggleDone('t1');
      expect(cubit.byId('t1')!.assignees, assignees);
    });

    test('assignees survive a feed resync of other events', () {
      final cubit = TaskCubit();
      final now = DateTime.now();
      final feed = const Feed(id: 'f1', name: 'REL 225', url: 'https://example.com/feed.ics');
      cubit.importFromFeed([_event('e1', now.add(const Duration(days: 3)))],
          feed);
      cubit.updateTask(cubit.state.single.copyWith(
        assignees: const [TaskAssignee(id: 'people/1', displayName: 'Amy')],
      ));
      cubit.importFromFeed([_event('e1', now.add(const Duration(days: 3)))],
          feed);
      expect(cubit.state.single.assignees.map((a) => a.id), ['people/1']);
    });

    test('upsertLinkedTaskForEvent carries event assignees', () {
      final cubit = TaskCubit();
      final now = DateTime.now();
      const assignees = [TaskAssignee(id: 'people/1', displayName: 'Amy')];
      final event = PlannerEvent(
        id: 'e1',
        subject: 'Dinner',
        start: now,
        end: now.add(const Duration(hours: 1)),
        assignees: assignees,
      );
      final taskId = cubit.upsertLinkedTaskForEvent(event);
      expect(cubit.byId(taskId)!.assignees, assignees);
      cubit.upsertLinkedTaskForEvent(
        event.copyWith(assignees: const [
          TaskAssignee(id: 'people/2', displayName: 'Rory'),
        ]),
      );
      expect(cubit.byId(taskId)!.assignees.map((a) => a.id), ['people/2']);
    });

    test('ensureShadowForFeedEvent syncs assignees from the event', () {
      final cubit = TaskCubit();
      final now = DateTime.now();
      final event = PlannerEvent(
        id: 'hw:f1:e1',
        subject: 'Study group',
        start: now,
        end: now.add(const Duration(hours: 1)),
        feedId: 'f1',
        assignees: const [TaskAssignee(id: 'people/1', displayName: 'Amy')],
      );
      cubit.ensureShadowForFeedEvent(event);
      expect(cubit.state.single.assignees.map((a) => a.id), ['people/1']);
      cubit.ensureShadowForFeedEvent(event.copyWith(assignees: const []));
      expect(cubit.state.single.assignees, isEmpty);
    });
  });
}
