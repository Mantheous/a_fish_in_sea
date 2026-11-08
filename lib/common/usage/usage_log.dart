import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../../demo/demo_mode.dart';
import 'usage_event.dart';

/// Append-only store behind [UsageLog]. Two implementations keep the log
/// testable without opening Hive in unit tests.
abstract class UsageStore {
  Future<Iterable<Object>> keys();
  Future<Object?> get(Object key);
  Future<void> put(Object key, Object? value);
  Future<void> deleteAll(Iterable<Object> keys);
}

class HiveUsageStore implements UsageStore {
  final Box<dynamic> box;
  HiveUsageStore(this.box);

  @override
  Future<Iterable<Object>> keys() async => box.keys.cast<Object>().toList();

  @override
  Future<Object?> get(Object key) async => box.get(key);

  @override
  Future<void> put(Object key, Object? value) async => box.put(key, value);

  @override
  Future<void> deleteAll(Iterable<Object> keys) async =>
      box.deleteAll(keys.toList());
}

class MemoryUsageStore implements UsageStore {
  final Map<Object, Object?> values = {};

  @override
  Future<Iterable<Object>> keys() async => values.keys.toList();

  @override
  Future<Object?> get(Object key) async => values[key];

  @override
  Future<void> put(Object key, Object? value) async => values[key] = value;

  @override
  Future<void> deleteAll(Iterable<Object> keys) async {
    for (final key in keys) {
      values.remove(key);
    }
  }
}

/// A batch read from the log. Keys are the storage keys to delete after the
/// server accepted the events; [events] is the sanitized wire payload.
class UsageBatch {
  final List<Object> keys;
  final List<Map<String, dynamic>> events;
  const UsageBatch(this.keys, this.events);
  bool get isEmpty => events.isEmpty;
}

/// Content-free, capped, on-device usage log.
///
/// Design constraints (see AGENTS.md):
/// - Never part of HydratedBloc or sync: a corrupt row is skipped, never a
///   reason to reset user data.
/// - Capped ring buffer (oldest rows pruned first) so an offline device or a
///   failed upload can never grow storage without bound.
/// - No user content: callers pass closed-set names; [usageMetaValue] drops
///   anything that is not a short token/number/bool.
///
/// The log is a singleton because screen transitions are recorded from a
/// navigation listener and from cubits that have no constructor seam.
class UsageLog {
  UsageLog._() : sessionId = _newSessionId();

  static final UsageLog instance = UsageLog._();

  /// Hard cap on queued events. ~150 bytes each, so the worst case is a few
  /// hundred KB in the app's own Hive box.
  static const int maxEvents = 2000;

  /// Rows older than this are dropped locally even if upload keeps failing.
  static const Duration maxAge = Duration(days: 30);

  UsageStore? _store;
  bool _ready = false;
  int _seq = 0;
  Future<void> _pending = Future<void>.value();
  String? _currentScreen;
  int? _screenStartedAtMs;
  late final String sessionId;

  bool get ready => _ready;
  String get currentScreen => _currentScreen ?? '';

  static String _newSessionId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return 's${now.toRadixString(36)}';
  }

  /// Opens the dedicated `usage_log` Hive box. Must run after Hive is
  /// initialized (main.dart does that during storage setup). Any failure
  /// disables the log for this launch rather than breaking boot.
  Future<void> open({UsageStore? store}) async {
    try {
      final resolved = store ?? HiveUsageStore(await _openBox());
      _store = resolved;
      _ready = true;
      await _pruneOld();
    } catch (error) {
      _ready = false;
      debugPrint('[usage] log disabled for this launch: $error');
    }
  }

  /// Opens the dedicated box, recovering once from a corrupt file. The log
  /// is disposable telemetry: losing queued events is preferable to a box
  /// that throws on every boot and disables the feature forever.
  Future<Box<dynamic>> _openBox() async {
    try {
      return await Hive.openBox<dynamic>('usage_log', crashRecovery: true);
    } catch (error) {
      debugPrint('[usage] box unreadable, recreating: $error');
      try {
        await Hive.deleteBoxFromDisk('usage_log');
      } catch (_) {
        // Web has no file to delete; the retry below will fail closed.
      }
      return Hive.openBox<dynamic>('usage_log', crashRecovery: true);
    }
  }

  /// Test seam: install an in-memory store without touching Hive.
  @visibleForTesting
  Future<void> openWithStore(UsageStore store) async {
    _store = store;
    _ready = true;
    await _pruneOld();
  }

  @visibleForTesting
  Future<void> resetForTest() async {
    final store = _store;
    if (store != null) {
      await store.deleteAll(await store.keys());
    }
    _ready = false;
    _store = null;
    _currentScreen = null;
    _screenStartedAtMs = null;
    _seq = 0;
  }

  bool get _enabled => _ready && !DemoMode.isActive;

  /// Records the current screen's dwell time and starts timing [name].
  /// Called by the navigation/auth listeners; a no-op when the screen has
  /// not actually changed (BlocListener can fire on identical states).
  void enterScreen(String name) {
    if (!_enabled) return;
    final next = usageName(name);
    if (_currentScreen == next) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final started = _screenStartedAtMs;
    if (_currentScreen != null && started != null) {
      _write(
        UsageEvent(
          id: _nextId(now),
          atMs: now,
          kind: 'screen',
          name: _currentScreen!,
          screen: _currentScreen!,
          durationMs: (now - started).clamp(0, 86400000),
          meta: {'to': next},
        ),
      );
    }
    _currentScreen = next;
    _screenStartedAtMs = now;
  }

  /// Stops the dwell clock (app backgrounded). The screen is logged with
  /// the time spent before the pause, and again on [resume].
  void pause() {
    if (!_enabled) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final screen = _currentScreen;
    final started = _screenStartedAtMs;
    if (screen != null && started != null) {
      _write(
        UsageEvent(
          id: _nextId(now),
          atMs: now,
          kind: 'screen',
          name: screen,
          screen: screen,
          durationMs: (now - started).clamp(0, 86400000),
          meta: const {'to': 'paused'},
        ),
      );
    }
    _screenStartedAtMs = null;
  }

  void resume() {
    if (!_enabled) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _screenStartedAtMs = now;
    _write(
      UsageEvent(
        id: _nextId(now),
        atMs: now,
        kind: 'app',
        name: 'resume',
        screen: _currentScreen ?? '',
      ),
    );
  }

  /// A named, closed-set interaction (e.g. `calendar.view.set`).
  void action(String name, {Map<String, Object?> meta = const {}}) {
    if (!_enabled) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _write(
      UsageEvent(
        id: _nextId(now),
        atMs: now,
        kind: 'action',
        name: usageName(name),
        screen: _currentScreen ?? '',
        meta: _sanitizeMeta(meta),
      ),
    );
  }

  /// An error type only — never the message/stack, which can contain user
  /// content. [error] is used for its runtime type name.
  void error(String name, Object error) {
    if (!_enabled) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _write(
      UsageEvent(
        id: _nextId(now),
        atMs: now,
        kind: 'error',
        name: usageName(name),
        screen: _currentScreen ?? '',
        meta: {'type': usageMetaValue(error.runtimeType.toString())},
      ),
    );
  }

  /// Records a slow or failed sync. Successful fast syncs are not logged:
  /// they happen every few minutes and would dominate the log.
  void sync({required int durationMs, required bool ok, int? statusCode}) {
    if (!_enabled) return;
    if (ok && durationMs < 8000) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _write(
      UsageEvent(
        id: _nextId(now),
        atMs: now,
        kind: ok ? 'slow' : 'sync',
        name: ok ? 'sync.slow' : 'sync.failed',
        screen: _currentScreen ?? '',
        durationMs: durationMs.clamp(0, 86400000),
        meta: {if (statusCode != null) 'status': statusCode},
      ),
    );
  }

  void appStart({required String platform}) {
    if (!_enabled) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _write(
      UsageEvent(
        id: _nextId(now),
        atMs: now,
        kind: 'app',
        name: 'start',
        screen: _currentScreen ?? '',
        meta: {'platform': usageMetaValue(platform)},
      ),
    );
  }

  String _nextId(int now) {
    _seq++;
    return '$now-${_seq.toRadixString(36)}-${sessionId.substring(1)}';
  }

  Map<String, Object?> _sanitizeMeta(Map<String, Object?> raw) {
    final out = <String, Object?>{};
    for (final entry in raw.entries) {
      if (out.length >= 8) break;
      final key = entry.key.toLowerCase();
      if (!RegExp(r'^[a-z][a-z0-9_]{0,23}$').hasMatch(key)) continue;
      final value = usageMetaValue(entry.value);
      if (value != null) out[key] = value;
    }
    return out;
  }

  void _write(UsageEvent event) {
    final store = _store;
    if (store == null) return;
    // Fire-and-forget: the UI must never wait on telemetry. Chaining keeps
    // event order and gives tests a single future to settle.
    _pending = _pending.then((_) => _put(store, event));
  }

  /// Test seam: waits for every queued write to hit the store.
  @visibleForTesting
  Future<void> settleForTest() => _pending;

  Future<void> _put(UsageStore store, UsageEvent event) async {
    try {
      final key = 'e:${event.atMs.toString().padLeft(13, '0')}:${event.id}';
      await store.put(key, event.toJson());
      final keys = (await store.keys()).cast<Object>().toList();
      if (keys.length > maxEvents) {
        keys.sort();
        final drop = keys.take(keys.length - maxEvents + 100).toList();
        await store.deleteAll(drop);
      }
    } catch (error) {
      debugPrint('[usage] event dropped: $error');
    }
  }

  Future<void> _pruneOld() async {
    final store = _store;
    if (store == null) return;
    try {
      final cutoff =
          DateTime.now().millisecondsSinceEpoch - maxAge.inMilliseconds;
      final stale = <Object>[];
      for (final key in await store.keys()) {
        if (key is String && key.startsWith('e:')) {
          final at = int.tryParse(key.substring(2, key.indexOf(':', 2)));
          if (at != null && at < cutoff) stale.add(key);
        }
      }
      if (stale.isNotEmpty) await store.deleteAll(stale);
    } catch (_) {
      // A prune failure is harmless; the cap still bounds storage.
    }
  }

  /// Returns the oldest [max] events without deleting them. The caller
  /// must call [ack] only after the server accepted the batch.
  Future<UsageBatch> takeBatch({int max = 250}) async {
    final store = _store;
    if (store == null) return const UsageBatch([], []);
    try {
      final keys = (await store.keys()).cast<Object>().toList()..sort();
      final selected = keys.take(max).toList();
      final events = <Map<String, dynamic>>[];
      final acceptedKeys = <Object>[];
      for (final key in selected) {
        final event = UsageEvent.tryFromJson(await store.get(key));
        if (event == null) {
          // Malformed or foreign row: drop it now so it cannot wedge the
          // queue forever.
          await store.deleteAll([key]);
          continue;
        }
        events.add(event.toJson());
        acceptedKeys.add(key);
      }
      return UsageBatch(acceptedKeys, events);
    } catch (error) {
      debugPrint('[usage] batch read failed: $error');
      return const UsageBatch([], []);
    }
  }

  Future<void> ack(Iterable<Object> keys) async {
    final store = _store;
    if (store == null || keys.isEmpty) return;
    try {
      await store.deleteAll(keys);
    } catch (error) {
      debugPrint('[usage] ack failed: $error');
    }
  }
}
