import 'dart:async';
import 'dart:convert';

import 'package:a_fish_in_sea/common/persistence/stable_storage_keys.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

/// Domain writes can stop while sync metadata still persists, matching the
/// separate HydratedBloc keys on a device interrupted during removal.
class DelayedStorage implements Storage {
  final data = <String, dynamic>{};
  final paused = Completer<void>();
  final metadataPaused = Completer<void>();
  bool pauseDomainWrites = false;
  bool pauseMetadataWrites = false;
  bool domainWriteStarted = false;
  bool pauseRestorationIntent = false;
  final restorationPaused = Completer<void>();

  @override
  dynamic read(String key) => data[key];

  @override
  Future<void> write(String key, dynamic value) async {
    if (pauseMetadataWrites && key == StableStorageKeys.syncMeta) {
      await metadataPaused.future;
    }
    if (pauseDomainWrites && key != StableStorageKeys.syncMeta) {
      domainWriteStarted = true;
      await paused.future;
    }
    data[key] = jsonDecode(jsonEncode(value));
    if (pauseRestorationIntent &&
        key == StableStorageKeys.syncMeta &&
        value is Map &&
        value['pendingRestoration'] == true) {
      await restorationPaused.future;
    }
  }

  @override
  Future<void> delete(String key) async => data.remove(key);
  @override
  Future<void> clear() async => data.clear();
  @override
  Future<void> close() async {}
}
