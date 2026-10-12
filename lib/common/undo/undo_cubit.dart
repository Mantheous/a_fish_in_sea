import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';

import 'change_record.dart';

class UndoState extends Equatable {
  final List<ChangeRecord> undoStack;
  final List<ChangeRecord> redoStack;

  const UndoState({this.undoStack = const [], this.redoStack = const []});

  @override
  List<Object?> get props => [undoStack, redoStack];
}

/// Session-scoped undo history.
///
/// Deliberately a plain [Cubit], not a hydrated one: every record holds
/// full before/after snapshots of the cubits it touches, so persisting the
/// stack re-serializes up to [maxDepth] full collections on *every* edit —
/// each tap slower than the last (marking off a batch of homework tasks
/// degraded until the tab crashed). Undo across an app restart is not a
/// supported flow; the cubits' own user data stays hydrated as before.
class UndoCubit extends Cubit<UndoState> {
  static const int maxDepth = 100;
  static UndoCubit? _instance;

  static UndoCubit? get instance => _instance;

  /// While > 0, [RevertableHydratedCubit.emitChange] emits without
  /// recording, so [RevertableHydratedCubit.atomic] can fold a multi-cubit
  /// gesture into a single undo step. Balanced push/pop; never negative.
  static int _suspendDepth = 0;
  static bool get isSuspended => _suspendDepth > 0;
  static void suspend() => _suspendDepth++;
  static void resume() {
    if (_suspendDepth > 0) _suspendDepth--;
  }

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
}
