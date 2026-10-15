import 'package:a_fish_in_sea/common/undo/change_record.dart';
import 'package:a_fish_in_sea/common/undo/revertable_hydrated_cubit.dart';
import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
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
}
