import '../../common/time/time_session.dart';
import '../../common/undo/revertable_hydrated_cubit.dart';
import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/service/node_event_link.dart';
import '../../nodes/service/node_event_sync.dart';
import '../../reporting/bloc/reporting_cubit.dart';
import '../bloc/calendar_cubit.dart';
import 'calendar_report.dart';

/// Writes a dragged report interval back to whichever store owns [block].
///
/// Manual entries stay manual and move between day buckets when the drag
/// crosses midnight. Timer blocks update the backing task (mirroring onto
/// its linked events) or the event itself when it owns the run. Live
/// blocks are read-only while recording.
///
/// Returns true when a record was changed.
bool applyReportedInterval({
  required ReportingCubit reporting,
  required CalendarCubit calendar,
  required NodeCubit nodes,
  required ReportBlock block,
  required DateTime start,
  required DateTime end,
}) {
  if (block.kind == ReportBlockKind.live) return false;
  final safeEnd = end.isAfter(start)
      ? end
      : start.add(const Duration(minutes: 1));

  final location = findReportEntryLocationByDisplayId(
    reporting.state,
    block.displayId,
  );
  if (location != null) {
    final entry = location.entry;
    final bucket = DateTime.tryParse(location.day);
    if (bucket == null) return false;
    if (entry.start == start && entry.end == safeEnd) return false;
    final updated = entry.copyWith(start: start, end: safeEnd);
    final oldDay = bucket;
    // Overnight reports may be stored under a day other than their start.
    // Keep that bucket unless the start actually crosses a calendar date.
    final sameStartDay =
        entry.start.year == start.year &&
        entry.start.month == start.month &&
        entry.start.day == start.day;
    final newDay = sameStartDay
        ? oldDay
        : DateTime(start.year, start.month, start.day);
    if (oldDay == newDay) {
      reporting.upsertEntry(oldDay, updated);
    } else {
      if (reporting.entriesForDay(newDay).any((e) => e.id == entry.id)) {
        return false;
      }
      RevertableHydratedCubit.atomic([reporting], () {
        reporting.deleteEntry(oldDay, entry.id);
        reporting.upsertEntry(newDay, updated);
      });
    }
    return true;
  }

  if (block.kind == ReportBlockKind.accepted) return false;

  final eventId = block.eventId;
  final sessionId = block.sessionId;
  if (eventId != null) {
    final backing = NodeEventLink.backingNodeFor(nodes, calendar, eventId);
    final event = calendar.byId(eventId);
    // A task created after recording need not own the event's old runs.
    // Prefer the task only when it actually has the requested session.
    final nodeSession = sessionById(
      backing?.recordedSessions ?? const [],
      sessionId,
    );
    if (backing != null && (sessionId == null || nodeSession != null)) {
      if (sessionId != null) {
        return NodeEventSync.setNodeSession(
          nodes,
          calendar,
          backing.id,
          sessionId,
          start,
          safeEnd,
        );
      }
      if (backing.recordedSessions.isNotEmpty ||
          event == null ||
          event.recordedSessions.isEmpty) {
        return NodeEventSync.setNodeReported(
          nodes,
          calendar,
          backing.id,
          start,
          safeEnd,
        );
      }
    }
    if (event == null) return false;
    final sessions = event.recordedSessions;
    final session = sessionId != null
        ? sessionById(sessions, sessionId)
        : (sessions.length == 1 ? sessions.single : null);
    if (sessionId != null && session == null) return false;
    if (session != null) {
      if (session.start == start && session.end == safeEnd) return false;
      calendar.updateSession(eventId, session.id, start, safeEnd);
    } else {
      if (sessions.length > 1) return false;
      calendar.setReported(eventId, start, safeEnd);
    }
    return true;
  }

  // Nodes recorded off the calendar carry the node id in their display id.
  if (block.displayId.startsWith(reportTimerDisplayIdPrefix)) {
    final nodeId = reportOwnerIdForDisplayId(block.displayId);
    if (nodeId == null) return false;
    final node = nodes.byId(nodeId);
    if (node == null) return false;
    if (sessionId != null) {
      return NodeEventSync.setNodeSession(
        nodes,
        calendar,
        node.id,
        sessionId,
        start,
        safeEnd,
      );
    } else if (node.recordedSessions.length == 1) {
      return NodeEventSync.setNodeSession(
        nodes,
        calendar,
        node.id,
        node.recordedSessions.single.id,
        start,
        safeEnd,
      );
    } else {
      return NodeEventSync.setNodeReported(
        nodes,
        calendar,
        node.id,
        start,
        safeEnd,
      );
    }
  }
  return false;
}

/// Deletes the recording behind [block]. Manual entries leave their day
/// bucket; recorded runs are removed from the task and its mirrored events
/// without touching the task's other runs.
///
/// Returns true when a record was changed.
bool deleteReportedBlock({
  required ReportingCubit reporting,
  required CalendarCubit calendar,
  required NodeCubit nodes,
  required ReportBlock block,
}) {
  if (block.kind == ReportBlockKind.live) return false;

  final location = findReportEntryLocationByDisplayId(
    reporting.state,
    block.displayId,
  );
  if (location != null) {
    final entry = location.entry;
    final bucket = DateTime.tryParse(location.day);
    if (bucket == null) return false;
    reporting.deleteEntry(bucket, entry.id);
    return true;
  }

  if (block.kind == ReportBlockKind.accepted) return false;

  final sessionId = block.sessionId;
  final eventId = block.eventId;
  if (eventId != null) {
    final backing = NodeEventLink.backingNodeFor(nodes, calendar, eventId);
    if (backing != null) {
      if (sessionId != null) {
        NodeEventSync.removeNodeSession(nodes, calendar, backing.id, sessionId);
      } else {
        NodeEventSync.clearNodeReported(nodes, calendar, backing.id);
      }
      return true;
    }
    final event = calendar.byId(eventId);
    if (event == null) return false;
    if (sessionId != null) {
      calendar.removeSession(eventId, sessionId);
    } else {
      calendar.clearReported(eventId);
    }
    return true;
  }

  if (block.displayId.startsWith(reportTimerDisplayIdPrefix)) {
    final nodeId = reportOwnerIdForDisplayId(block.displayId);
    if (nodeId == null) return false;
    final node = nodes.byId(nodeId);
    if (node == null) return false;
    if (sessionId != null) {
      NodeEventSync.removeNodeSession(nodes, calendar, node.id, sessionId);
    } else {
      NodeEventSync.clearNodeReported(nodes, calendar, node.id);
    }
    return true;
  }
  return false;
}
