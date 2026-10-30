part of 'calendar_report.dart';

/// Every distinct recorded run on an event and the tasks linked to it.
///
/// Task-event pairs mirror the same sessions, so ids dedupe the copies.
/// When any side carries an explicit session list, legacy aggregate
/// intervals are ignored: those spans would otherwise show up as an extra
/// block after the first multi-session stop.
List<TimeSession> _recordedSessions(PlannerEvent event, List<Node> linked) {
  final explicit = <String, TimeSession>{};
  for (final session in event.sessions) {
    explicit[session.id] = session;
  }
  for (final node in linked) {
    for (final session in node.sessions) {
      explicit[session.id] = session;
    }
  }
  if (explicit.isNotEmpty) return _sortedSessions(explicit.values);

  final legacy = <String, TimeSession>{};
  for (final session in event.recordedSessions) {
    legacy[session.id] = session;
  }
  for (final node in linked) {
    for (final session in node.recordedSessions) {
      legacy[session.id] = session;
    }
  }
  return _sortedSessions(legacy.values);
}

List<TimeSession> _sortedSessions(Iterable<TimeSession> sessions) =>
    sessions.toList()..sort((a, b) => a.start.compareTo(b.start));
