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

/// Which of a task's plan events a recording belongs to.
///
/// Toggl-style attribution: an entry sits on the row it happened during, so
/// a task planned twice (say Monday 9am and Wednesday 2pm) shows Monday's
/// run on Monday and Wednesday's on Wednesday instead of stacking both on
/// one of them. Picks the event with the largest overlap, then the nearest
/// one; ties break on earliest start, then id, so the choice is stable
/// across rebuilds.
String? _ownerEventId(
  List<PlannerEvent> candidates,
  DateTime start,
  DateTime end,
) {
  if (candidates.isEmpty) return null;
  PlannerEvent? best;
  var bestOverlap = -1;
  var bestGap = -1;
  for (final event in candidates) {
    final overlap = _overlapSeconds(event, start, end);
    final gap = _gapSeconds(event, start, end);
    final better =
        best == null ||
        overlap > bestOverlap ||
        (overlap == bestOverlap && gap < bestGap) ||
        (overlap == bestOverlap &&
            gap == bestGap &&
            (event.start.isBefore(best.start) ||
                (event.start == best.start &&
                    event.id.compareTo(best.id) < 0)));
    if (better) {
      best = event;
      bestOverlap = overlap;
      bestGap = gap;
    }
  }
  return best?.id;
}

int _overlapSeconds(PlannerEvent event, DateTime start, DateTime end) {
  final from = start.isAfter(event.start) ? start : event.start;
  final to = end.isBefore(event.end) ? end : event.end;
  return to.isAfter(from) ? to.difference(from).inSeconds : 0;
}

int _gapSeconds(PlannerEvent event, DateTime start, DateTime end) {
  if (!end.isBefore(event.start) && !start.isAfter(event.end)) return 0;
  if (end.isBefore(event.start)) return event.start.difference(end).inSeconds;
  return start.difference(event.end).inSeconds.abs();
}
