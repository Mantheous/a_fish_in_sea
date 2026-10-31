import '../../common/time/local_date.dart';
import '../model/node.dart';

/// Recorded days contributing minutes to `[start, end)`, or the existing
/// calendar anchor when a task has no recordings.
Iterable<DateTime> taskDaysInWindow(
  Node node,
  DateTime start,
  DateTime end,
) sync* {
  final sessions = node.recordedSessions;
  if (sessions.isEmpty) {
    final anchor =
        node.actualStart ?? node.schedule?.start ?? node.schedule?.due;
    if (anchor != null) yield localDay(anchor);
    return;
  }
  for (final session in sessions) {
    final from = session.start.isBefore(start) ? start : session.start;
    final to = session.end.isAfter(end) ? end : session.end;
    if (to.difference(from).inMinutes <= 0) continue;
    for (
      var day = localDay(from);
      day.isBefore(to);
      day = shiftLocalDay(day, 1)
    ) {
      yield day;
    }
  }
}
