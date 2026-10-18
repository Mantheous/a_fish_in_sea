import 'package:a_fish_in_sea/common/undo/change_record.dart';
import 'package:a_fish_in_sea/common/undo/revertable_hydrated_cubit.dart';
import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/planner/bloc/assignment_rules_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  late Storage storage;

  setUp(() {
    RevertableRegistry.reset();
    storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  group('UndoCubit', () {
    test('undo and redo restore task state', () {
      final undoCubit = UndoCubit();
      final nodeCubit = NodeCubit();
      nodeCubit.addNode(Node(id: 't1', title: 'Read', createdAt: DateTime(2026)));
      expect(undoCubit.canUndo, isTrue);
      undoCubit.undo();
      expect(nodeCubit.state, isEmpty);
      expect(undoCubit.canRedo, isTrue);
      undoCubit.redo();
      expect(nodeCubit.state.single.id, 't1');
    });

    test('new mutation clears redo stack', () {
      final undoCubit = UndoCubit();
      final nodeCubit = NodeCubit();
      nodeCubit.addNode(Node(id: 't1', title: 'Read', createdAt: DateTime(2026)));
      undoCubit.undo();
      expect(undoCubit.canRedo, isTrue);
      nodeCubit.addNode(Node(id: 't2', title: 'Pray', createdAt: DateTime(2026)));
      expect(undoCubit.canRedo, isFalse);
      undoCubit.undo();
      expect(nodeCubit.state, isEmpty);
      expect(undoCubit.canUndo, isFalse);
    });

    test('stack is bounded by maxDepth', () {
      final undoCubit = UndoCubit();
      final nodeCubit = NodeCubit();
      for (var i = 0; i < UndoCubit.maxDepth + 10; i++) {
        nodeCubit.addNode(Node(id: 't$i', title: 'Task $i', createdAt: DateTime(2026)));
      }
      expect(undoCubit.state.undoStack.length, UndoCubit.maxDepth);
      for (var i = 0; i < UndoCubit.maxDepth; i++) {
        undoCubit.undo();
      }
      expect(undoCubit.canUndo, isFalse);
      expect(nodeCubit.state.length, 10);
    });

    test('change record serialization round trip', () {
      const record = ChangeRecord(entries: [
        StateSnapshot(
          cubitId: 'NodeCubit',
          before: {'nodes': []},
          after: {'nodes': []},
        ),
      ]);
      final restored = ChangeRecord.fromJson(record.toJson());
      expect(restored, record);
    });

    test('undo history is session-scoped and never written to storage', () {
      final undoCubit = UndoCubit();
      final nodeCubit = NodeCubit();
      for (var i = 0; i < 5; i++) {
        nodeCubit.addNode(
            Node(id: 't$i', title: 'Task $i', createdAt: DateTime(2026)));
      }
      expect(undoCubit.state.undoStack.length, 5);
      // Full snapshots stay in memory only: persisting up to maxDepth full
      // collections on every edit made each tap slower than the last.
      verifyNever(() => storage.write('UndoCubit', any()));
      // In-session undo still works.
      undoCubit.undo();
      expect(nodeCubit.state.length, 4);
    });

    test('toggleEventDone is one undo step and keeps the node done', () {
      final undoCubit = UndoCubit();
      final calendar = CalendarCubit();
      final nodes = NodeCubit();
      final now = DateTime(2026, 10, 11, 9);
      calendar.emit([
        PlannerEvent(
          id: 'e1',
          subject: 'Task',
          start: now,
          end: now.add(const Duration(hours: 1)),
          isTask: true,
          taskId: 'node:e1',
        ),
      ]);
      nodes.emit([
        Node(
          id: 'node:e1',
          title: 'Task',
          createdAt: now,
          calendarEventId: 'e1',
        ),
      ]);

      NodeEventLink.toggleEventDone(calendar, nodes, 'e1');
      expect(calendar.byId('e1')!.done, isTrue);
      expect(nodes.byId('node:e1')!.isDone, isTrue);
      expect(undoCubit.state.undoStack.length, 1);

      NodeEventLink.toggleEventDone(calendar, nodes, 'e1');
      expect(calendar.byId('e1')!.done, isFalse);
      expect(nodes.byId('node:e1')!.isDone, isFalse);
      expect(undoCubit.state.undoStack.length, 2);

      undoCubit.undo();
      expect(calendar.byId('e1')!.done, isTrue);
      expect(nodes.byId('node:e1')!.isDone, isTrue);
      undoCubit.redo();
      expect(calendar.byId('e1')!.done, isFalse);
      expect(nodes.byId('node:e1')!.isDone, isFalse);
    });
  });

  group('task toggles stay cheap', () {
    PlannerEvent taskEvent(String id) => PlannerEvent(
          id: id,
          subject: 'Assignment',
          start: DateTime(2026, 9, 12, 9),
          end: DateTime(2026, 9, 12, 10),
          isTask: true,
        );

    Node backingNode(String id, String eventId) => Node(
          id: id,
          title: 'Assignment',
          createdAt: DateTime(2026, 9, 1),
          calendarEventId: eventId,
        );

    test('node checkbox toggle is one undo step and undoes both sides',
        () {
      final undoCubit = UndoCubit();
      final nodeCubit = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(taskEvent('e1'));
      nodeCubit.addNode(backingNode('n1', 'e1'));
      final steps = undoCubit.state.undoStack.length;

      NodeEventLink.toggleNodeDone(nodeCubit, calendar, 'n1');

      expect(undoCubit.state.undoStack.length, steps + 1);
      expect(nodeCubit.byId('n1')?.isDone, isTrue);
      expect(calendar.byId('e1')?.done, isTrue);
      undoCubit.undo();
      expect(nodeCubit.byId('n1')?.isDone, isFalse);
      expect(calendar.byId('e1')?.done, isFalse);
    });

    test('event toggle mirrors to backing nodes in one step', () {
      final undoCubit = UndoCubit();
      final nodeCubit = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(taskEvent('e1'));
      nodeCubit.addNode(backingNode('n1', 'e1'));
      final steps = undoCubit.state.undoStack.length;

      NodeEventLink.toggleEventDone(calendar, nodeCubit, 'e1');

      expect(undoCubit.state.undoStack.length, steps + 1);
      expect(nodeCubit.byId('n1')?.isDone, isTrue);
      expect(calendar.byId('e1')?.done, isTrue);
    });

    test('atomic skips unchanged cubits', () {
      final undoCubit = UndoCubit();
      final nodeCubit = NodeCubit();
      final calendar = CalendarCubit();
      nodeCubit.addNode(backingNode('n1', 'e1'));
      final steps = undoCubit.state.undoStack.length;

      RevertableHydratedCubit.atomic([nodeCubit, calendar], () {
        nodeCubit.toggleDone('n1');
      });

      expect(undoCubit.state.undoStack.length, steps + 1);
      final record = undoCubit.state.undoStack.last;
      expect(
        record.entries.map((e) => e.cubitId),
        ['NodeCubit'],
      );
    });

    test('batch creates are one undo step', () {
      final undoCubit = UndoCubit();
      final nodeCubit = NodeCubit();

      RevertableHydratedCubit.atomic([nodeCubit], () {
        for (var i = 0; i < 3; i++) {
          nodeCubit.addNode(Node(
            id: 'batch-$i',
            title: 'Batch task $i',
            createdAt: DateTime(2026),
          ));
        }
      });

      expect(nodeCubit.state, hasLength(3));
      expect(undoCubit.state.undoStack, hasLength(1));
      undoCubit.undo();
      expect(nodeCubit.state, isEmpty);
      undoCubit.redo();
      expect(nodeCubit.state, hasLength(3));
    });

    test('atomic restores all stores and records nothing when a write fails', () {
      final undoCubit = UndoCubit();
      final nodeCubit = NodeCubit();
      final calendar = CalendarCubit();

      expect(
        () => RevertableHydratedCubit.atomic([nodeCubit, calendar], () {
          nodeCubit.addNode(Node(
            id: 'partial',
            title: 'Partial write',
            createdAt: DateTime(2026),
          ));
          calendar.addEvent(PlannerEvent(
            id: 'partial-event',
            subject: 'Partial event',
            start: DateTime(2026),
            end: DateTime(2026, 1, 1, 1),
          ));
          throw StateError('later write failed');
        }),
        throwsStateError,
      );

      expect(nodeCubit.state, isEmpty);
      expect(calendar.state, isEmpty);
      expect(undoCubit.state.undoStack, isEmpty);
    });

    test('linked node delete is one undo step for node and reverse event link', () {
      final undoCubit = UndoCubit();
      final nodeCubit = NodeCubit();
      final calendar = CalendarCubit();
      nodeCubit.addNode(Node(
        id: 'n1',
        title: 'Task',
        createdAt: DateTime(2026),
      ));
      calendar.addEvent(PlannerEvent(
        id: 'e1',
        subject: 'Task block',
        start: DateTime(2026, 9, 12, 9),
        end: DateTime(2026, 9, 12, 10),
        isTask: true,
        taskId: 'n1',
      ));
      final stepsBeforeDelete = undoCubit.state.undoStack.length;

      final removed = NodeEventLink.deleteNodesAndUnlink(
        nodeCubit,
        calendar,
        {'n1'},
      );

      expect(removed, 1);
      expect(nodeCubit.byId('n1'), isNull);
      expect(calendar.byId('e1')?.taskId, isNull);
      expect(undoCubit.state.undoStack.length, stepsBeforeDelete + 1);
      undoCubit.undo();
      expect(nodeCubit.byId('n1'), isNotNull);
      expect(calendar.byId('e1')?.taskId, 'n1');
      expect(calendar.byId('e1')?.isTask, isTrue);
    });

    test('event delete and backing-node removal undo together', () {
      final undoCubit = UndoCubit();
      final nodeCubit = NodeCubit();
      final calendar = CalendarCubit();
      final event = PlannerEvent(
        id: 'e1',
        subject: 'Personal task',
        start: DateTime(2026, 9, 12, 9),
        end: DateTime(2026, 9, 12, 10),
        isTask: true,
        taskId: 'node:e1',
      );
      nodeCubit.addNode(Node(
        id: 'node:e1',
        title: 'Personal task',
        createdAt: DateTime(2026),
        calendarEventId: 'e1',
      ));
      calendar.addEvent(event);
      final stepsBeforeDelete = undoCubit.state.undoStack.length;

      NodeEventLink.deleteEventAndNodes(calendar, nodeCubit, event);

      expect(calendar.byId('e1'), isNull);
      expect(nodeCubit.byId('node:e1'), isNull);
      expect(undoCubit.state.undoStack.length, stepsBeforeDelete + 1);
      undoCubit.undo();
      expect(calendar.byId('e1')?.taskId, 'node:e1');
      expect(nodeCubit.byId('node:e1')?.calendarEventId, 'e1');
    });

    test('clearing failed keeps done nodes done', () {
      UndoCubit();
      final nodeCubit = NodeCubit();
      final done = backingNode('done', 'e1').copyWith(
        status: NodeStatus.done,
        completedAt: DateTime(2026, 9, 10),
      );
      final failed = backingNode('failed', 'e1').copyWith(
        status: NodeStatus.failed,
      );
      nodeCubit.addNode(done);
      nodeCubit.addNode(failed);

      nodeCubit.setFailedForEvent('e1', false);

      expect(nodeCubit.byId('failed')?.status, NodeStatus.open);
      expect(nodeCubit.byId('done')?.isDone, isTrue);
    });
  });

  group('delete/import undo restores every side (issue #74)', () {
    Node homeworkNode(String id, DateTime base) => Node(
          id: id,
          title: 'Video Quiz 3.1',
          createdAt: base,
          sourceEventId: 'feed:$id',
          feedId: 'math290',
          classId: 'math290',
          schedule: ScheduleFacet(due: base, start: base, end: base),
        );

    PlannerEvent linkedEvent(String id, String taskId) => PlannerEvent(
          id: id,
          subject: 'Video Quiz 3.1',
          start: DateTime(2026, 9, 12, 9),
          end: DateTime(2026, 9, 12, 10),
          isTask: true,
          taskId: taskId,
        );

    test('bulk mark-done mirrors in one undo step', () {
      final undoCubit = UndoCubit();
      final nodeCubit = NodeCubit();
      final calendar = CalendarCubit();
      final base = DateTime(2030, 2, 7, 9);
      nodeCubit.addNode(
          homeworkNode('n1', base).copyWith(calendarEventId: 'e1'));
      calendar.addEvent(linkedEvent('e1', 'n1'));
      final steps = undoCubit.state.undoStack.length;

      final changed = NodeEventLink.setNodesDone(
        nodeCubit,
        calendar,
        {'n1'},
        done: true,
      );

      expect(changed, 1);
      expect(nodeCubit.byId('n1')?.isDone, isTrue);
      expect(calendar.byId('e1')?.done, isTrue);
      expect(undoCubit.state.undoStack.length, steps + 1);

      undoCubit.undo();
      expect(nodeCubit.byId('n1')?.isDone, isFalse);
      expect(calendar.byId('e1')?.done, isFalse);
    });

    test('single delete with direct link is one undo step', () {
      final undoCubit = UndoCubit();
      final nodeCubit = NodeCubit();
      final calendar = CalendarCubit();
      final base = DateTime(2030, 2, 7, 9);
      nodeCubit.addNode(
          homeworkNode('n1', base).copyWith(calendarEventId: 'e1'));
      calendar.addEvent(linkedEvent('e1', 'n1'));
      final steps = undoCubit.state.undoStack.length;

      final removed =
          NodeEventLink.deleteNodesAndUnlink(nodeCubit, calendar, {'n1'});

      expect(removed, 1);
      expect(nodeCubit.byId('n1'), isNull);
      expect(calendar.byId('e1')!.isTask, isFalse);
      expect(calendar.byId('e1')!.taskId, isNull);
      expect(undoCubit.state.undoStack.length, steps + 1);

      undoCubit.undo();
      expect(nodeCubit.byId('n1')?.title, 'Video Quiz 3.1');
      expect(nodeCubit.byId('n1')?.calendarEventId, 'e1');
      expect(calendar.byId('e1')!.isTask, isTrue);
      expect(calendar.byId('e1')!.taskId, 'n1');
    });

    test('rule save + dues apply undo together', () {
      final undoCubit = UndoCubit();
      final nodeCubit = NodeCubit();
      final rules = AssignmentRulesCubit();
      final base = DateTime(2030, 2, 7, 9);
      nodeCubit.addNode(homeworkNode('hw:math290:q1', base));
      final steps = undoCubit.state.undoStack.length;

      // Mirrors the rules sheet Save: rule create + dues shift as one step.
      RevertableHydratedCubit.atomic([rules, nodeCubit], () {
        rules.createRule(
          feedId: 'math290',
          templateKey: 'video quiz',
          displayName: 'Video Quiz',
          dueOffsetDays: -2,
        );
        nodeCubit.retargetAssignmentDues(
          feedId: 'math290',
          templateKey: 'video quiz',
          newOffsetDays: -2,
        );
      });

      expect(undoCubit.state.undoStack.length, steps + 1);
      expect(rules.state.single.dueOffsetDays, -2);
      expect(nodeCubit.byId('hw:math290:q1')?.schedule?.due,
          base.subtract(const Duration(days: 2)));

      undoCubit.undo();
      expect(rules.state, isEmpty);
      expect(nodeCubit.byId('hw:math290:q1')?.schedule?.due, base);
    });
  });
}
