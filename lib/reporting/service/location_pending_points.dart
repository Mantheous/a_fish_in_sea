import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../model/tracked_point.dart';

const String _configFileName = 'tracking_config.json';
const String _pendingFileName = 'tracking_pending_points.json';

Future<Directory> _docsDir() => getApplicationDocumentsDirectory();

Future<File> _configFile() async =>
    File('${(await _docsDir()).path}/$_configFileName');

String _queueName(String? account) => account == null
    ? _pendingFileName
    : 'tracking_account_${base64Url.encode(utf8.encode(account))}.json';

Future<File> _pendingFile(String? account) async =>
    File('${(await _docsDir()).path}/${_queueName(account)}');

Future<Map<String, dynamic>> readTrackingConfig() async {
  if (kIsWeb) return {};
  try {
    return Map<String, dynamic>.from(
      jsonDecode(await (await _configFile()).readAsString()) as Map,
    );
  } catch (_) {
    return {};
  }
}

/// Older active recordings stored only the interval. Presence of either
/// ownership key identifies a newer config, including a revoked null session.
Future<int?> readLegacyTrackingInterval() async {
  final config = await readTrackingConfig();
  final interval = config['intervalMinutes'];
  if (interval is! num ||
      !interval.isFinite ||
      config.containsKey('account') ||
      config.containsKey('session')) {
    return null;
  }
  return interval.toInt().clamp(1, 15);
}

Future<void> writeTrackingConfig(
  int intervalMinutes, {
  String? account,
  String? session,
}) async {
  if (kIsWeb) return;
  try {
    final file = await _configFile();
    final temporary = File('${file.path}.writing');
    await temporary.writeAsString(
      jsonEncode({
        'intervalMinutes': intervalMinutes,
        'account': account,
        'session': session,
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  } on MissingPluginException {
    // Headless/unsupported platforms have no mobile queue.
  }
}

/// Invalidates the service isolate's token before account ownership changes.
Future<void> invalidateTrackingSampling() async {
  final config = await readTrackingConfig();
  await writeTrackingConfig(
    await readTrackingInterval(),
    account: config['account'] is String ? config['account'] as String : null,
  );
}

Future<int> readTrackingInterval({int fallback = 5}) async {
  try {
    final raw = await (await _configFile()).readAsString();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return ((json['intervalMinutes'] as num?)?.toInt() ?? fallback).clamp(
      1,
      15,
    );
  } catch (_) {
    return fallback;
  }
}

Future<void> appendPendingPoint(TrackedPoint point, {String? account}) async {
  try {
    final file = await _pendingFile(account);
    var list = <dynamic>[];
    if (await file.exists()) {
      try {
        list = jsonDecode(await file.readAsString()) as List<dynamic>;
      } catch (_) {}
    }
    list.add(point.toJson());
    await file.writeAsString(jsonEncode(list));
  } catch (_) {}
}

Future<List<TrackedPoint>> takePendingPoints({String? account}) async {
  try {
    final file = await _pendingFile(account);
    // Recover batches orphaned by a crash between the rename below and the
    // delete after it, so they are merged instead of lost.
    final stale = await _drainStaleClaims(file.parent, _queueName(account));
    if (!await file.exists()) return stale;
    // Claim the batch with an atomic rename: a background append racing this
    // take lands in a fresh file instead of being deleted with the batch.
    final claimed = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.taking',
    );
    try {
      await file.rename(claimed.path);
    } catch (_) {
      return stale;
    }
    final decoded = await _readClaimedBatch(claimed);
    return [...stale, ...decoded];
  } catch (_) {
    return const [];
  }
}

/// Puts a claimed batch back into the pending file (e.g. the merging widget
/// unmounted mid-take). Prepended so chronological order survives the next
/// take; [mergePoints] sorts again on the way in.
Future<void> requeuePendingPoints(
  List<TrackedPoint> points, {
  String? account,
}) async {
  if (points.isEmpty) return;
  try {
    final file = await _pendingFile(account);
    var existing = <dynamic>[];
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is List) existing = decoded;
      } catch (_) {}
    }
    final mine = points.map((p) => p.toJson()).toList();
    await file.writeAsString(jsonEncode([...mine, ...existing]));
  } catch (_) {}
}

Future<List<TrackedPoint>> _readClaimedBatch(
  File claimed, {
  bool remove = true,
}) async {
  try {
    final decoded = jsonDecode(await claimed.readAsString());
    if (decoded is! List) return const [];
    final out = <TrackedPoint>[];
    for (final e in decoded) {
      try {
        if (e is Map) {
          out.add(TrackedPoint.fromJson(Map<String, dynamic>.from(e)));
        }
      } catch (_) {}
    }
    return out;
  } catch (_) {
    return const [];
  } finally {
    try {
      if (remove) await claimed.delete();
    } catch (_) {}
  }
}

Future<List<TrackedPoint>> _drainStaleClaims(
  Directory dir,
  String namePrefix, {
  bool remove = true,
}) async {
  final out = <TrackedPoint>[];
  try {
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final name = e.path.split(Platform.pathSeparator).last;
      if (!name.startsWith('$namePrefix.') || !name.endsWith('.taking')) {
        continue;
      }
      out.addAll(await _readClaimedBatch(e, remove: remove));
    }
  } catch (_) {}
  return out;
}

/// Non-destructive read: the account snapshot must be durable before a queue
/// batch can be consumed. Orphaned claims belong to the same account too.
Future<List<TrackedPoint>> readPendingPoints({String? account}) async {
  if (kIsWeb) return const [];
  try {
    final file = await _pendingFile(account);
    return [
      ...await _drainStaleClaims(
        file.parent,
        _queueName(account),
        remove: false,
      ),
      if (await file.exists()) ...await _readClaimedBatch(file, remove: false),
    ];
  } on MissingPluginException {
    return const [];
  }
}

/// Claim legacy device-wide files for their existing owner. Atomic renames
/// keep the data recoverable even if the app stops before the next snapshot.
Future<void> claimLegacyPendingPoints(String account) async {
  if (kIsWeb) return;
  try {
    final legacy = await _pendingFile(null);
    final owned = await _pendingFile(account);
    await for (final entry in legacy.parent.list()) {
      if (entry is! File) continue;
      if (entry.path != legacy.path &&
          !(entry.path.startsWith('${legacy.path}.') &&
              entry.path.endsWith('.taking'))) {
        continue;
      }
      await entry.rename(
        '${owned.path}.legacy.${DateTime.now().microsecondsSinceEpoch}.taking',
      );
    }
  } on MissingPluginException {
    // No mobile queue on this platform.
  }
}

/// A service tick always belongs to the session that started it. Re-reading
/// after the GPS await rejects results even after a new account starts sampling.
Future<void> samplePendingPoint(
  String session,
  Future<TrackedPoint?> Function() sample,
) async {
  final config = await readTrackingConfig();
  if (config['session'] != session || config['account'] is! String) return;
  final point = await sample();
  if (point == null || (await readTrackingConfig())['session'] != session) {
    return;
  }
  await appendPendingPoint(point, account: config['account'] as String);
}
