import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../demo/demo_mode.dart';
import '../../sync/auth_cubit.dart';
import '../../sync/sync_client.dart';
import 'usage_log.dart';

/// Ships queued [UsageLog] events to `/api/v1/usage/events`.
///
/// Best-effort by design: a failed flush keeps the events in the capped
/// local queue, and the next timer (or app pause) retries. Nothing here
/// blocks the UI, and nothing is sent while signed out or in demo mode.
class UsageReporter {
  final AuthCubit auth;
  final SyncClient client;
  final UsageLog log;
  final Duration interval;
  Timer? _timer;
  bool _flushing = false;
  DateTime? _lastFlushStarted;

  UsageReporter({
    required this.auth,
    required this.client,
    UsageLog? log,
    this.interval = const Duration(minutes: 15),
  }) : log = log ?? UsageLog.instance;

  void start() {
    if (_timer != null) return;
    log.appStart(platform: _platformLabel);
    _timer = Timer.periodic(interval, (_) => unawaited(flush()));
    // Give the first frame and auth restore time to settle.
    unawaited(Future<void>.delayed(const Duration(seconds: 20), flush));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Sends at most one batch per call. Kept idempotent so the poll timer,
  /// the lifecycle hook, and a manual flush cannot double-send the same
  /// rows (the server also dedupes by event id).
  Future<void> flush() async {
    if (_flushing) return;
    if (!log.ready || DemoMode.isActive || !auth.state.isSignedIn) return;
    final started = DateTime.now();
    // Avoid a hot loop when the app is paused and the network is down: a
    // failed flush retries on the next timer tick at most once a minute.
    final last = _lastFlushStarted;
    if (last != null &&
        started.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _lastFlushStarted = started;
    _flushing = true;
    try {
      final batch = await log.takeBatch();
      if (batch.isEmpty) return;
      final accepted = await client.apiPost('/api/v1/usage/events', {
        'events': batch.events,
        'platform': _platformLabel,
        'session_id': log.sessionId,
      });
      // A nil body means a proxy/captive portal answered without JSON; the
      // server returns {"accepted": n} on success, so only ack on a map.
      if (accepted is Map) {
        await log.ack(batch.keys);
      }
    } catch (error) {
      // Offline / signed out / server hiccup: keep rows for the next try.
      debugPrint('[usage] flush deferred: $error');
    } finally {
      _flushing = false;
    }
  }

  void pause() {
    log.pause();
    unawaited(flush());
  }

  void resume() => log.resume();

  static String get _platformLabel {
    if (kIsWeb) return 'web';
    return defaultTargetPlatform.name;
  }
}
