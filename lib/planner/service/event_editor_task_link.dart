import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/model/node.dart';
import '../bloc/calendar_cubit.dart';
import '../model/planner_event.dart';

/// Mirrors the editor's task flag and locally owned work interval.
void syncEditorTaskLink(
  NodeCubit nodes,
  CalendarCubit calendar,
  PlannerEvent saved, {
  required bool syncFeedWorkTime,
}) {
  if (!saved.isTask) {
    final seeded = seededSourceNode(nodes, saved.id, saved.taskId);
    if (seeded != null) {
      // Unmarking the block must keep the task that scheduled it.
      nodes.setScheduleBlock(seeded.id, saved.start, saved.end);
      return;
    }
    nodes.removeNodesForEvent(saved.id);
    return;
  }
  if (saved.isFromFeed) {
    nodes.ensureNodeForFeedEvent(saved);
    if (syncFeedWorkTime) {
      for (final node in nodes.nodesForEventId(saved.id)) {
        // Only the work interval follows the editor. The assignment's due
        // date, completion, and recorded/running timer remain independent.
        nodes.updateNode(
          node.copyWith(
            schedule: (node.schedule ?? const ScheduleFacet()).copyWith(
              start: saved.start,
              end: saved.end,
              allDay: saved.allDay,
            ),
          ),
        );
      }
    }
    nodes.setDoneForEvent(
      saved.id,
      done: saved.done,
      completedAt: saved.completedAt,
      taskId: saved.taskId,
    );
    return;
  }
  final nodeId = nodes.upsertLinkedNodeForEvent(saved);
  calendar.setTaskLink(saved.id, nodeId);
  nodes.setDoneForEvent(
    saved.id,
    done: saved.done,
    completedAt: saved.completedAt,
    taskId: saved.taskId ?? nodeId,
  );
}

/// The surviving task that seeded an event through "Add to calendar".
/// Synthetic event-backed tasks are disposable and excluded here.
Node? seededSourceNode(NodeCubit nodes, String eventId, String? linkedId) {
  if (linkedId == null || linkedId == 'node:$eventId') return null;
  final node = nodes.byId(linkedId);
  if (node == null || node.calendarEventId != eventId) return null;
  return node;
}
