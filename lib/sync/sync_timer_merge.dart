import 'package:a_fish_in_sea/common/time/time_session.dart';

/// Canonical server timestamp for sync metadata.
String syncRecordStamp(DateTime timestamp) =>
    timestamp.toUtc().toIso8601String();

/// Preserves a live timer during server-wins conflict resolution.
///
/// [preserveLocalSessions] is false for an unchanged, already-synced item:
/// missing remote sessions must stay deleted. Without a baseline, or with
/// unsent item edits, retain local sessions conservatively.
///
/// Offset-less timestamps from older payloads remain readable through
/// [DateTime.tryParse]; new node/event JSON writes these values in UTC.
void preserveRunningTimer(
  String collection,
  Map<String, dynamic>? local,
  Map<String, dynamic> merged, {
  required bool preserveLocalSessions,
}) {
  if (preserveLocalSessions) {
    preserveRecordedSessions(collection, local, merged);
  }
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
/// Remote wins when both sides carry the same session id, so two devices
/// that edited one run converge instead of ping-ponging forever. Local runs
/// with new ids are appended; a legacy-only aggregate that overlaps them is
/// ignored so the gap between two runs is never counted as extra work.
void preserveRecordedSessions(
  String collection,
  Map<String, dynamic>? local,
  Map<String, dynamic> merged,
) {
  if (collection != 'nodes' && collection != 'events') return;
  final localExplicit = TimeSession.listFromJson(local?['sessions']);
  final localLegacy = _legacySession(local);
  final remoteExplicit = TimeSession.listFromJson(merged['sessions']);
  final remoteLegacy = _legacySession(merged);
  final localSessions = localExplicit.isNotEmpty
      ? localExplicit
      : [if (localLegacy != null) localLegacy];

  var combined = remoteExplicit;
  if (combined.isEmpty &&
      remoteLegacy != null &&
      !_overlapsAny(remoteLegacy, localSessions)) {
    combined = [remoteLegacy];
  }
  for (final session in localSessions) {
    if (sessionById(combined, session.id) != null) continue;
    // A legacy-only local pair is usually the aggregate of the remote runs;
    // adding it would count the gaps between them as work.
    if (localExplicit.isEmpty && _overlapsAny(session, combined)) continue;
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

TimeSession? _legacySession(Map<String, dynamic>? payload) {
  if (payload == null) return null;
  return TimeSession.legacySession(
    _payloadDate(payload['actualStart']),
    _payloadDate(payload['actualEnd']),
  );
}

bool _overlapsAny(TimeSession session, Iterable<TimeSession> others) =>
    others.any(
      (other) =>
          session.start.isBefore(other.end) && session.end.isAfter(other.start),
    );

DateTime? _payloadDate(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toLocal();
}

/// Device-specific preferences never roam in either direction.
void stripDeviceLocalSyncFields(String collection, Map<String, dynamic> data) {
  if (collection == 'settings') {
    data.remove('icalProxyBase');
    data.remove('ankiConnectHost');
    data.remove('defaultCalendarView');
  } else if (collection == 'plaid') {
    data.remove('wasConnected');
  }
}
