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
