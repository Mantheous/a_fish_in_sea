import 'package:hydrated_bloc/hydrated_bloc.dart';

/// Ephemeral in-memory [Storage] used for the whole demo session.
///
/// While demo mode is active, [HydratedBloc.storage] points here, so every
/// cubit emit lands in this map and the real on-disk box is never touched.
/// Dropping the instance (exit demo, or a mid-demo kill) discards all mock
/// state: nothing demoed persists between sessions.
class DemoStorage implements Storage {
  final Map<String, dynamic> _box = {};

  @override
  dynamic read(String key) => _box[key];

  @override
  Future<void> write(String key, dynamic value) async {
    _box[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _box.remove(key);
  }

  @override
  Future<void> clear() async {
    _box.clear();
  }

  @override
  Future<void> close() async {
    _box.clear();
  }
}
