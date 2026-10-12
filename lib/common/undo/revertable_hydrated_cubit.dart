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
    final before = toJson(state) ?? const <String, dynamic>{};
    emit(newState);
    final after = toJson(newState) ?? const <String, dynamic>{};
    undo.record(ChangeRecord.single(StateSnapshot(
      cubitId: changeId,
      before: before,
      after: after,
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
    if (undo == null || UndoCubit.isSuspended) {
      action();
      return;
    }
    final beforeStates = <RevertableHydratedCubit, Object?>{
      for (final c in cubits) c: c.state,
    };
    final befores = <RevertableHydratedCubit, Map<String, dynamic>>{
      for (final c in cubits)
        c: c.toJson(c.state) ?? const <String, dynamic>{},
    };
    UndoCubit.suspend();
    try {
      action();
    } finally {
      UndoCubit.resume();
    }
    final entries = <StateSnapshot>[];
    for (final c in cubits) {
      if (identical(c.state, beforeStates[c])) continue;
      entries.add(StateSnapshot(
        cubitId: c.changeId,
        before: befores[c]!,
        after: c.toJson(c.state) ?? const <String, dynamic>{},
      ));
    }
    undo.record(ChangeRecord(entries: entries));
  }
}
