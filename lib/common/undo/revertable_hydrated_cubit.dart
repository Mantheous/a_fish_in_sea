import 'package:hydrated_bloc/hydrated_bloc.dart';

import 'change_record.dart';
import 'undo_cubit.dart';

abstract class RevertableHydratedCubit<T> extends HydratedCubit<T>
    implements Revertable {
  RevertableHydratedCubit(super.initialState) {
    RevertableRegistry.register(this);
  }

  @override
  Future<void> close() {
    RevertableRegistry.unregister(this);
    return super.close();
  }

  @override
  String get changeId => runtimeType.toString();

  @override
  void applyState(Object? state) {
    if (state is T) {
      emit(state);
    }
  }

  @override
  void applyJson(Map<String, dynamic>? json) {
    if (json == null) return;
    try {
      final restored = fromJson(json);
      if (restored != null) emit(restored);
    } catch (_) {}
  }

  /// Reverts only the ids [entry] changed, keeping ids that arrived after
  /// the edit (background sync pulls, feed imports) intact. Falls back to a
  /// conditional full restore when the snapshots are legacy JSON-only or an
  /// unrecognized shape.
  @override
  void applyUndo(StateSnapshot entry) {
    final before = entry.stateBefore;
    final after = entry.stateAfter;
    if (before is T && after is T) {
      final merged = _mergeTyped(before, after, state, isUndo: true);
      if (!identical(merged, state)) emit(merged);
      return;
    }
    final beforeJson = entry.before;
    final afterJson = entry.after;
    if (beforeJson != null && afterJson != null) {
      try {
        final currentJson = toJson(state);
        if (currentJson != null) {
          final mergedJson = mergeUndoJson(
            beforeJson,
            afterJson,
            Map<String, dynamic>.from(currentJson),
            isUndo: true,
          );
          if (mergedJson != null) {
            final restored = fromJson(mergedJson);
            if (restored != null) {
              emit(restored);
              return;
            }
          }
        }
      } catch (_) {}
    }
    if (before is T && identical(state, after)) emit(before);
  }

  /// Re-applies only the ids [entry] changed. Mirrors [applyUndo].
  @override
  void applyRedo(StateSnapshot entry) {
    final before = entry.stateBefore;
    final after = entry.stateAfter;
    if (before is T && after is T) {
      final merged = _mergeTyped(before, after, state, isUndo: false);
      if (!identical(merged, state)) emit(merged);
      return;
    }
    final beforeJson = entry.before;
    final afterJson = entry.after;
    if (beforeJson != null && afterJson != null) {
      try {
        final currentJson = toJson(state);
        if (currentJson != null) {
          final mergedJson = mergeUndoJson(
            beforeJson,
            afterJson,
            Map<String, dynamic>.from(currentJson),
            isUndo: false,
          );
          if (mergedJson != null) {
            final restored = fromJson(mergedJson);
            if (restored != null) {
              emit(restored);
              return;
            }
          }
        }
      } catch (_) {}
    }
    if (after is T && identical(state, before)) emit(after);
  }

  /// Merges [before]/[after] snapshots against [current] so undo/redo only
  /// touches the user's own changed ids. Fast path: with no intervening
  /// change the target restores exactly (order preserved).
  T _mergeTyped(T before, T after, T current, {required bool isUndo}) {
    final source = isUndo ? after : before;
    final target = isUndo ? before : after;
    if (identical(current, source)) return target;
    try {
      final beforeJson = toJson(before);
      final afterJson = toJson(after);
      final currentJson = toJson(current);
      if (beforeJson == null || afterJson == null || currentJson == null) {
        return current;
      }
      final mergedJson = mergeUndoJson(
        Map<String, dynamic>.from(beforeJson),
        Map<String, dynamic>.from(afterJson),
        Map<String, dynamic>.from(currentJson),
        isUndo: isUndo,
      );
      if (mergedJson == null) return current;
      if (undoJsonEquals(mergedJson, currentJson)) return current;
      return fromJson(mergedJson) ?? current;
    } catch (_) {
      return current;
    }
  }

  void emitChange(T newState) {
    final undo = UndoCubit.instance;
    // Fast path: no undo history to record (e.g. tests), or recording
    // suspended inside [atomic] — skip the record. Sync pulls apply merged
    // state via plain emits, never [emitChange], so pulled ids never enter
    // the undo stack; replay ([applyUndo]/[applyRedo]) is item-scoped, so
    // history safely survives pulls.
    if (undo == null || UndoCubit.isSuspended) {
      emit(newState);
      return;
    }
    final before = state;
    emit(newState);
    undo.record(ChangeRecord.single(StateSnapshot(
      cubitId: changeId,
      stateBefore: before,
      stateAfter: newState,
    )));
  }

  /// Runs [action], folding every change to [cubits] into ONE undo record.
  ///
  /// A task checkbox tap touches NodeCubit + CalendarCubit; without this
  /// each touch records its own full before/after snapshots (2 records per
  /// tap), so rapid marking fills the stack with near-duplicate full
  /// collections and every later tap pays to re-serialize all of them.
  /// Cubits whose state object is identical afterwards are skipped, so
  /// no-op mirrors cost nothing. Not nestable: a nested call inside
  /// [action] just runs — the outer record already covers it.
  static void atomic(
    List<RevertableHydratedCubit> cubits,
    void Function() action,
  ) {
    final undo = UndoCubit.instance;
    if (UndoCubit.isSuspended) {
      action();
      return;
    }
    final beforeStates = <RevertableHydratedCubit, Object?>{
      for (final c in cubits) c: c.state,
    };
    final recordsUndo = undo != null;
    if (recordsUndo) UndoCubit.suspend();
    try {
      action();
    } catch (error, stackTrace) {
      // A compound gesture must not leave half of its stores mutated when
      // one of its later writes fails. Restore every changed participant
      // before propagating the original error to the caller.
      for (final c in cubits.reversed) {
        final before = beforeStates[c];
        if (identical(before, c.state)) continue;
        try {
          c.applyState(before);
        } catch (_) {
          // Preserve the original failure; captured cubit states should
          // normally be accepted by their owning cubits.
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      if (recordsUndo) UndoCubit.resume();
    }
    if (undo == null) return;
    final entries = <StateSnapshot>[];
    for (final c in cubits) {
      final beforeState = beforeStates[c];
      final afterState = c.state;
      if (identical(beforeState, afterState)) continue;
      entries.add(StateSnapshot(
        cubitId: c.changeId,
        stateBefore: beforeState,
        stateAfter: afterState,
      ));
    }
    if (entries.isNotEmpty) {
      undo.record(ChangeRecord(entries: entries));
    }
  }
}
