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
    // resetHistory) — skip the double full-state toJson, which is O(n)
    // string allocs per edit for list cubits.
    if (undo == null) {
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
}
