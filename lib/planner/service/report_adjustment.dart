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
/// its linked events) or the event itself when no task backs it. Live
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

  final entry = findReportEntryByDisplayId(reporting.state, block.displayId);
  if (entry != null) {
    final updated = entry.copyWith(start: start, end: safeEnd);
    final oldDay = DateTime(
      entry.start.year,
      entry.start.month,
      entry.start.day,
    );
    final newDay = DateTime(start.year, start.month, start.day);
    if (oldDay == newDay) {
      reporting.upsertEntry(oldDay, updated);
    } else {
      RevertableHydratedCubit.atomic([reporting], () {
        reporting.deleteEntry(oldDay, entry.id);
        reporting.upsertEntry(newDay, updated);
      });
    }
    return true;
  }

  final eventId = block.eventId;
  final sessionId = block.sessionId;
  if (eventId != null) {
    final backing = NodeEventLink.backingNodeFor(nodes, calendar, eventId);
    if (backing != null) {
      if (sessionId != null) {
        NodeEventSync.setNodeSession(
          nodes,
          calendar,
          backing.id,
          sessionId,
          start,
          safeEnd,
        );
      } else {
        NodeEventSync.setNodeReported(
          nodes,
          calendar,
          backing.id,
          start,
          safeEnd,
        );
      }
      return true;
    }
    final event = calendar.byId(eventId);
    if (event == null) return false;
    if (sessionId != null) {
      calendar.updateSession(eventId, sessionId, start, safeEnd);
    } else {
      calendar.updateEvent(
        event.copyWith(
          actualStart: start,
          actualEnd: safeEnd,
          clearTimerStartedAt: true,
        ),
      );
    }
    return true;
  }

  // Nodes recorded off the calendar carry the node id in their display id.
  if (block.displayId.startsWith(reportTimerDisplayIdPrefix)) {
    final nodeId = reportOwnerIdForDisplayId(block.displayId);
    final node = nodes.byId(nodeId);
    if (node == null) return false;
    if (sessionId != null) {
      NodeEventSync.setNodeSession(
        nodes,
        calendar,
        node.id,
        sessionId,
        start,
        safeEnd,
      );
    } else {
      NodeEventSync.setNodeReported(nodes, calendar, node.id, start, safeEnd);
    }
    return true;
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

  final entry = findReportEntryByDisplayId(reporting.state, block.displayId);
  if (entry != null) {
    final day = DateTime(entry.start.year, entry.start.month, entry.start.day);
    reporting.deleteEntry(day, entry.id);
    return true;
  }

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
