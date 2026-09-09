import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/task_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/model/task.dart';
import 'package:a_fish_in_sea/planner/service/task_event_link.dart';
import 'package:a_fish_in_sea/planner/service/task_tracking.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

Task task(
  String id,
  String title, {
  DateTime? plannedStart,
  DateTime? plannedEnd,
  DateTime? due,
}) =>
    Task(
      id: id,
      title: title,
      plannedStart: plannedStart,
      plannedEnd: plannedEnd,
      due: due,
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

  group('Task tracking fields', () {
    test('round trip preserves planned, reported, timer and failed', () {
      final day = DateTime(2026, 9, 7, 9);
      final tracked = Task(
        id: 't1',
        title: 'Study',
        plannedStart: day,
        plannedEnd: day.add(const Duration(hours: 1)),
        actualStart: day.add(const Duration(minutes: 5)),
        actualEnd: day.add(const Duration(minutes: 50)),
        timerStartedAt: day.add(const Duration(minutes: 2)),
        failed: true,
      );
      expect(Task.fromJson(tracked.toJson()), tracked);
    });

    test('old payloads without tracking keys still load', () {
      final json = const Task(id: 't1', title: 'Read').toJson()
        ..remove('plannedStart')
        ..remove('plannedEnd')
        ..remove('actualStart')
        ..remove('actualEnd')
        ..remove('timerStartedAt')
        ..remove('failed');
      final restored = Task.fromJson(json);
      expect(restored.hasPlanned, isFalse);
      expect(restored.hasReported, isFalse);
      expect(restored.isTracking, isFalse);
      expect(restored.failed, isFalse);
    });

    test('corrupt tracking dates do not drop the task', () {
      final json = const Task(id: 't1', title: 'Read').toJson()
        ..['plannedStart'] = 'not-a-date'
        ..['actualStart'] = 'not-a-date'
        ..['timerStartedAt'] = 'not-a-date';
      final restored = Task.fromJson(json);
      expect(restored.id, 't1');
      expect(restored.hasPlanned, isFalse);
      expect(restored.isTracking, isFalse);
    });
  });

  group('TaskCubit tracking', () {
    test('start then stop saves the reported interval', () {
      final cubit = TaskCubit();
      cubit.addTask(task('t1', 'Study',
          plannedStart: DateTime(2026, 9, 7, 9),
          plannedEnd: DateTime(2026, 9, 7, 10)));
      final t0 = DateTime(2026, 9, 7, 9, 2);
      cubit.startTracking('t1', now: t0);
      expect(cubit.byId('t1')?.isTracking, isTrue);
      final t1 = DateTime(2026, 9, 7, 9, 47);
      cubit.stopTracking('t1', now: t1);
      final done = cubit.byId('t1')!;
      expect(done.isTracking, isFalse);
      expect(done.actualStart, t0);
      expect(done.actualEnd, t1);
      expect(done.reportedDuration, const Duration(minutes: 45));
    });

    test('starting a second timer saves the first', () {
      final cubit = TaskCubit();
      cubit.addTask(const Task(id: 't1', title: 'One'));
      cubit.addTask(const Task(id: 't2', title: 'Two'));
      cubit.startTracking('t1', now: DateTime(2026, 9, 7, 9, 5));
      cubit.startTracking('t2', now: DateTime(2026, 9, 7, 10, 1));
      expect(cubit.byId('t1')?.isTracking, isFalse);
      expect(cubit.byId('t1')?.hasReported, isTrue);
      expect(cubit.byId('t2')?.isTracking, isTrue);
      expect(cubit.activeTrackingId, 't2');
    });

    test('done tasks cannot start tracking', () {
      final cubit = TaskCubit();
      cubit.addTask(const Task(id: 't1', title: 'Old', done: true));
      cubit.startTracking('t1');
      expect(cubit.byId('t1')?.isTracking, isFalse);
      expect(cubit.activeTrackingId, isNull);
    });

    test('marking failed stops the timer and clears done', () {
      final cubit = TaskCubit();
      cubit.addTask(const Task(id: 't1', title: 'Study'));
      cubit.startTracking('t1', now: DateTime(2026, 9, 7, 9, 5));
      cubit.setFailed('t1', true, now: DateTime(2026, 9, 7, 9, 6));
      final failed = cubit.byId('t1')!;
      expect(failed.failed, isTrue);
      expect(failed.done, isFalse);
      expect(failed.isTracking, isFalse);
      expect(failed.hasReported, isTrue);
      cubit.setFailed('t1', false);
      expect(cubit.byId('t1')?.failed, isFalse);
    });

    test('completing a failed task clears failed', () {
      final cubit = TaskCubit();
      cubit.addTask(const Task(id: 't1', title: 'Study'));
      cubit.setFailed('t1', true);
      expect(cubit.byId('t1')?.failed, isTrue);
      cubit.toggleDone('t1');
      expect(cubit.byId('t1')?.done, isTrue);
      expect(cubit.byId('t1')?.failed, isFalse);
    });

    test('planned interval set, clear and round trip', () {
      final cubit = TaskCubit();
      cubit.addTask(const Task(id: 't1', title: 'Study'));
      cubit.setPlannedInterval(
        't1',
        DateTime(2026, 9, 8, 14),
        DateTime(2026, 9, 8, 15),
      );
      expect(cubit.byId('t1')?.hasPlanned, isTrue);
      final restored = cubit.fromJson(cubit.toJson(cubit.state));
      expect(restored?.single.hasPlanned, isTrue);
      cubit.clearPlannedInterval('t1');
      expect(cubit.byId('t1')?.hasPlanned, isFalse);
    });

    test('tracking survives a json round trip', () {
      final cubit = TaskCubit();
      cubit.addTask(const Task(id: 't1', title: 'Study'));
      cubit.startTracking('t1', now: DateTime(2026, 9, 7, 9, 5));
      final restored = cubit.fromJson(cubit.toJson(cubit.state));
      expect(restored?.single.isTracking, isTrue);
    });
  });

  group('selectTaskTracking', () {
    test('splits recording, current, previous, next and unscheduled', () {
      final now = DateTime(2026, 9, 7, 10, 30);
      final tasks = [
        task('prev', 'Prev',
            plannedStart: DateTime(2026, 9, 7, 8),
            plannedEnd: DateTime(2026, 9, 7, 9)),
        task('now', 'Now',
            plannedStart: DateTime(2026, 9, 7, 10),
            plannedEnd: DateTime(2026, 9, 7, 11)),
        task('next1', 'Next 1',
            plannedStart: DateTime(2026, 9, 7, 12),
            plannedEnd: DateTime(2026, 9, 7, 13)),
        task('next2', 'Next 2',
            plannedStart: DateTime(2026, 9, 7, 14),
            plannedEnd: DateTime(2026, 9, 7, 15)),
        task('plain', 'No block', due: DateTime(2026, 9, 8)),
        const Task(id: 'done', title: 'Finished', done: true),
      ];
      final sel = selectTaskTracking(tasks, now);
      expect(sel.recording, isNull);
      expect(sel.current.map((t) => t.id), ['now']);
      expect(sel.previous.map((t) => t.id), ['prev']);
      expect(sel.next.map((t) => t.id), ['next1', 'next2']);
      expect(sel.unscheduled.map((t) => t.id), ['plain']);
      expect(sel.isEmpty, isFalse);
    });

    test('recording task is surfaced even without a planned block', () {
      final cubit = TaskCubit();
      cubit.addTask(const Task(id: 't1', title: 'Freeform'));
      cubit.startTracking('t1', now: DateTime(2026, 9, 7, 10));
      final sel = selectTaskTracking(
        cubit.state,
        DateTime(2026, 9, 7, 10, 5),
      );
      expect(sel.recording?.id, 't1');
      expect(sel.unscheduled, isEmpty);
    });

    test('empty when every task is done', () {
      final sel = selectTaskTracking(
        [const Task(id: 'd', title: 'Done', done: true)],
        DateTime(2026, 9, 7, 10),
      );
      expect(sel.isEmpty, isTrue);
    });
  });

  group('TaskEventLink failed mirroring', () {
    late CalendarCubit calendar;
    late TaskCubit tasks;

    PlannerEvent personal(String id, DateTime start) => PlannerEvent(
          id: id,
          subject: 'Event $id',
          start: start,
          end: start.add(const Duration(hours: 1)),
        );

    setUp(() {
      UndoCubit();
      calendar = CalendarCubit();
      tasks = TaskCubit();
    });

    test('failing a task mirrors onto its event and back', () {
      calendar.addEvent(personal('evt:1', DateTime(2026, 9, 4, 9)));
      TaskEventLink.markEventAsTask(calendar, tasks, 'evt:1');
      final taskId = tasks.state.single.id;
      TaskEventLink.setTaskFailed(tasks, calendar, taskId, true);
      expect(tasks.byId(taskId)!.failed, isTrue);
      expect(tasks.byId(taskId)!.done, isFalse);
      expect(calendar.byId('evt:1')!.failed, isTrue);
      TaskEventLink.setTaskFailed(tasks, calendar, taskId, false);
      expect(calendar.byId('evt:1')!.failed, isFalse);
    });

    test('failing an event mirrors onto its task', () {
      calendar.addEvent(personal('evt:1', DateTime(2026, 9, 4, 9)));
      TaskEventLink.markEventAsTask(calendar, tasks, 'evt:1');
      final taskId = tasks.state.single.id;
      TaskEventLink.setEventFailed(calendar, tasks, 'evt:1', true);
      expect(calendar.byId('evt:1')!.failed, isTrue);
      expect(tasks.byId(taskId)!.failed, isTrue);
      expect(tasks.byId(taskId)!.done, isFalse);
    });

    test('completing a failed task clears failed on both sides', () {
      calendar.addEvent(personal('evt:1', DateTime(2026, 9, 4, 9)));
      TaskEventLink.markEventAsTask(calendar, tasks, 'evt:1');
      final taskId = tasks.state.single.id;
      TaskEventLink.setTaskFailed(tasks, calendar, taskId, true);
      TaskEventLink.toggleTaskDone(tasks, calendar, taskId);
      expect(tasks.byId(taskId)!.done, isTrue);
      expect(tasks.byId(taskId)!.failed, isFalse);
      expect(calendar.byId('evt:1')!.done, isTrue);
      expect(calendar.byId('evt:1')!.failed, isFalse);
    });

    test('linked tasks inherit the event planned block', () {
      final start = DateTime(2026, 9, 4, 9);
      calendar.addEvent(personal('evt:1', start));
      TaskEventLink.markEventAsTask(calendar, tasks, 'evt:1');
      final linked = tasks.state.single;
      expect(linked.plannedStart, start);
      expect(linked.plannedEnd, start.add(const Duration(hours: 1)));
    });
  });
}
