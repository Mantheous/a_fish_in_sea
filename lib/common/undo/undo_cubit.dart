import 'package:equatable/equatable.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

import 'change_record.dart';

class UndoState extends Equatable {
  final List<ChangeRecord> undoStack;
  final List<ChangeRecord> redoStack;

  const UndoState({this.undoStack = const [], this.redoStack = const []});

  @override
  List<Object?> get props => [undoStack, redoStack];
}

class UndoCubit extends HydratedCubit<UndoState> {
  static const int maxDepth = 100;
  static UndoCubit? _instance;

  static UndoCubit? get instance => _instance;

  UndoCubit() : super(const UndoState()) {
    _instance = this;
  }

  @override
  Future<void> close() {
    if (_instance == this) _instance = null;
    return super.close();
  }

  bool get canUndo => state.undoStack.isNotEmpty;
  bool get canRedo => state.redoStack.isNotEmpty;

  void record(ChangeRecord record) {
    if (record.entries.isEmpty) return;
    final undo = [...state.undoStack, record];
    while (undo.length > maxDepth) {
      undo.removeAt(0);
    }
    emit(UndoState(undoStack: undo, redoStack: const []));
  }

  void undo() {
    if (!canUndo) return;
    final record = state.undoStack.last;
    for (final entry in record.entries.reversed) {
      RevertableRegistry.byId(entry.cubitId)?.applyJson(entry.before);
    }
    emit(
      UndoState(
        undoStack: [...state.undoStack]..removeLast(),
        redoStack: [...state.redoStack, record],
      ),
    );
  }

  void redo() {
    if (!canRedo) return;
    final record = state.redoStack.last;
    for (final entry in record.entries) {
      RevertableRegistry.byId(entry.cubitId)?.applyJson(entry.after);
    }
    emit(
      UndoState(
        undoStack: [...state.undoStack, record],
        redoStack: [...state.redoStack]..removeLast(),
      ),
    );
  }

  void resetHistory() => emit(const UndoState());

  @override
  UndoState? fromJson(Map<String, dynamic> json) {
    final undo = (json['undoStack'] as List<dynamic>? ?? [])
        .map((e) => ChangeRecord.fromJson(e as Map<String, dynamic>))
        .toList();
    final redo = (json['redoStack'] as List<dynamic>? ?? [])
        .map((e) => ChangeRecord.fromJson(e as Map<String, dynamic>))
        .toList();
    return UndoState(undoStack: undo, redoStack: redo);
  }

  @override
  Map<String, dynamic> toJson(UndoState state) => {
        'undoStack': state.undoStack.map((e) => e.toJson()).toList(),
        'redoStack': state.redoStack.map((e) => e.toJson()).toList(),
      };
}
