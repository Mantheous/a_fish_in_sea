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
    List<ChangeRecord> decode(Object? value) {
      final out = <ChangeRecord>[];
      if (value is List) {
        for (final item in value) {
          try {
            final record = ChangeRecord.fromJson(
              Map<String, dynamic>.from(item as Map),
            );
            if (record.entries.isNotEmpty) out.add(record);
          } catch (_) {}
        }
      }
      return out;
    }

    try {
      return UndoState(
        undoStack: decode(json['undoStack']),
        redoStack: decode(json['redoStack']),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Map<String, dynamic> toJson(UndoState state) => {
        'undoStack': state.undoStack.map((e) => e.toJson()).toList(),
        'redoStack': state.redoStack.map((e) => e.toJson()).toList(),
      };
}
