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
/// session this device just finished, and an old-client payload that only
/// knows the legacy `actualStart`/`actualEnd` pair must not erase runs this
/// device already has.
///
/// The kept runs are unioned with the remote list (by session id). A session
/// deleted locally can be resurrected when another device still has it; that
/// is deliberately preferred over silently losing recorded time, which is
/// unrecoverable. The aggregate `actualStart`/`actualEnd` span is recomputed
/// from the union to stay consistent for older readers.
void preserveRecordedSessions(
  String collection,
  Map<String, dynamic>? local,
  Map<String, dynamic> merged,
) {
  if (collection != 'nodes' && collection != 'events') return;
  final localSessions = _sessionsWithOwnLegacy(local);
  if (localSessions.isEmpty) return;
  final remoteSessions = _sessionsWithOwnLegacy(merged);
  var combined = remoteSessions;
  for (final session in localSessions) {
    combined = withSession(combined, session);
  }
  if (combined.isEmpty) return;
  merged['sessions'] = [for (final session in combined) session.toJson()];
  final span = sessionSpan(combined);
  if (span != null) {
    merged['actualStart'] = span.start.toUtc().toIso8601String();
    merged['actualEnd'] = span.end.toUtc().toIso8601String();
  }
}

/// Sessions plus a legacy-only interval that disagrees with them. Compares
/// against this payload's own span, not the merged span, so an older aggregate
/// pair is not mistaken for an extra run.
List<TimeSession> _sessionsWithOwnLegacy(Map<String, dynamic>? payload) {
  if (payload == null) return const [];
  return sessionsWithLegacySpan(
    TimeSession.listFromJson(payload['sessions']),
    _payloadDate(payload['actualStart']),
    _payloadDate(payload['actualEnd']),
  );
}

DateTime? _payloadDate(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toLocal();
}
