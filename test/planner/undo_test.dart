import 'package:a_fish_in_sea/common/undo/change_record.dart';
import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/task_cubit.dart';
import 'package:a_fish_in_sea/planner/model/task.dart';
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
      final taskCubit = TaskCubit();
      taskCubit.addTask(const Task(id: 't1', title: 'Read'));
      expect(undoCubit.canUndo, isTrue);
      undoCubit.undo();
      expect(taskCubit.state, isEmpty);
      expect(undoCubit.canRedo, isTrue);
      undoCubit.redo();
      expect(taskCubit.state.single.id, 't1');
    });

    test('new mutation clears redo stack', () {
      final undoCubit = UndoCubit();
      final taskCubit = TaskCubit();
      taskCubit.addTask(const Task(id: 't1', title: 'Read'));
      undoCubit.undo();
      expect(undoCubit.canRedo, isTrue);
      taskCubit.addTask(const Task(id: 't2', title: 'Pray'));
      expect(undoCubit.canRedo, isFalse);
      undoCubit.undo();
      expect(taskCubit.state, isEmpty);
      expect(undoCubit.canUndo, isFalse);
    });

    test('stack is bounded by maxDepth', () {
      final undoCubit = UndoCubit();
      final taskCubit = TaskCubit();
      for (var i = 0; i < UndoCubit.maxDepth + 10; i++) {
        taskCubit.addTask(Task(id: 't$i', title: 'Task $i'));
      }
      expect(undoCubit.state.undoStack.length, UndoCubit.maxDepth);
      for (var i = 0; i < UndoCubit.maxDepth; i++) {
        undoCubit.undo();
      }
      expect(undoCubit.canUndo, isFalse);
      expect(taskCubit.state.length, 10);
    });

    test('change record serialization round trip', () {
      const record = ChangeRecord(entries: [
        StateSnapshot(
          cubitId: 'TaskCubit',
          before: {'tasks': []},
          after: {'tasks': []},
        ),
      ]);
      final restored = ChangeRecord.fromJson(record.toJson());
      expect(restored, record);
    });
  });
}
