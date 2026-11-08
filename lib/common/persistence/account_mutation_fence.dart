import 'package:hydrated_bloc/hydrated_bloc.dart';

/// Stops edits, undo replay and late callbacks while account stores are being
/// removed/restored. The fence is per store, so another device is unaffected.
mixin AccountMutationFence<T> on HydratedCubit<T> {
  bool accountMutationsBlocked = false;
  int _accountWriteDepth = 0;

  @override
  void emit(T state) {
    if (accountMutationsBlocked && _accountWriteDepth == 0) return;
    super.emit(state);
  }

  /// Only synchronous account clearing/restoration may bypass the fence.
  /// Async callbacks cannot inherit permission to mutate the next account.
  static void write(
    Iterable<AccountMutationFence<dynamic>> stores,
    void Function() action,
  ) {
    for (final store in stores) {
      store._accountWriteDepth++;
    }
    try {
      action();
    } finally {
      for (final store in stores) {
        store._accountWriteDepth--;
      }
    }
  }
}
