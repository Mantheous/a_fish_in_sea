import 'package:a_fish_in_sea/common/undo/change_record.dart';
import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
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
  });
}
