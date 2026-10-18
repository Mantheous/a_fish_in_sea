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

  void emitChange(T newState) {
    final undo = UndoCubit.instance;
    // Fast path: no undo history to record (e.g. tests, or sync which calls
    // resetHistory), or recording suspended inside [atomic] — skip the
    // double full-state toJson, which is O(n) string allocs per edit for
    // list cubits.
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
