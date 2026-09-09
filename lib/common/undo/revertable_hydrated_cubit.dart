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
    final before = toJson(state) ?? const <String, dynamic>{};
    emit(newState);
    final after = toJson(newState) ?? const <String, dynamic>{};
    UndoCubit.instance
        ?.record(ChangeRecord.single(StateSnapshot(
          cubitId: changeId,
          before: before,
          after: after,
        )));
  }
}
