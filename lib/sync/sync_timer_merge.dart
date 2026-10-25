import 'package:a_fish_in_sea/common/time/time_session.dart';

/// Canonical server timestamp for sync metadata.
String syncRecordStamp(DateTime timestamp) =>
    timestamp.toUtc().toIso8601String();

/// Preserves a live timer during server-wins conflict resolution.
///
/// Offset-less timestamps from older payloads remain readable through
/// [DateTime.tryParse]; new node/event JSON writes these values in UTC.
void preserveRunningTimer(
  String collection,
  Map<String, dynamic>? local,
  Map<String, dynamic> merged,
) {
  preserveRecordedSessions(collection, local, merged);
  if (collection != 'nodes' && collection != 'events') return;
  final localStart = local?['timerStartedAt'];
  if (localStart is! String || localStart.isEmpty) return;
  final localDt = DateTime.tryParse(localStart);
  if (localDt == null) return;
  final remoteStart = merged['timerStartedAt'];
  final remoteDt = remoteStart is String && remoteStart.isNotEmpty
      ? DateTime.tryParse(remoteStart)
      : null;
  if (remoteDt != null) {
    if (localDt.isBefore(remoteDt)) merged['timerStartedAt'] = localStart;
    return;
  }
  final remoteEndRaw = merged['actualEnd'];
  final remoteEnd = remoteEndRaw is String && remoteEndRaw.isNotEmpty
      ? DateTime.tryParse(remoteEndRaw)
      : null;
  if (remoteEnd == null || !remoteEnd.isAfter(localDt)) {
    merged['timerStartedAt'] = localStart;
  }
}

/// Preserves not-yet-pushed recorded runs during server-wins conflict
/// resolution. A remote payload with an older latest run must not erase a
/// session this device just finished; deletes still win because they leave
/// the local latest end unchanged.
///
/// The kept runs are unioned with the remote list (by session id) so a
/// session recorded on another device is not dropped just because this
/// device also has a newer one. The aggregate `actualStart`/`actualEnd`
/// span is recomputed from the union to stay consistent for older readers.
void preserveRecordedSessions(
  String collection,
  Map<String, dynamic>? local,
  Map<String, dynamic> merged,
) {
  if (collection != 'nodes' && collection != 'events') return;
  final localSessions = TimeSession.listFromJson(local?['sessions']);
  if (localSessions.isEmpty) return;
  final localLatest = _latestSessionEnd(localSessions);
  if (localLatest == null) return;
  final remoteSessions = TimeSession.listFromJson(merged['sessions']);
  final remoteLatest = _latestSessionEnd(remoteSessions);
  if (remoteLatest != null && !localLatest.isAfter(remoteLatest)) return;
  var combined = remoteSessions;
  for (final session in localSessions) {
    combined = withSession(combined, session);
  }
  merged['sessions'] = [for (final session in combined) session.toJson()];
  final span = sessionSpan(combined);
  if (span != null) {
    merged['actualStart'] = span.start.toUtc().toIso8601String();
    merged['actualEnd'] = span.end.toUtc().toIso8601String();
  }
}

DateTime? _latestSessionEnd(List<TimeSession> sessions) {
  DateTime? latest;
  for (final session in sessions) {
    if (!session.isValid) continue;
    if (latest == null || session.end.isAfter(latest)) latest = session.end;
  }
  return latest;
}
