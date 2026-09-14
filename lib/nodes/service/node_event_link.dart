import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';

/// Coordinates the two-way link between actionable events
/// ([PlannerEvent.isTask]) and their backing [Node]s so completion stays
/// in sync whichever side is toggled.
///
/// Backing-node shapes (see [NodeCubit]):
/// - personal events → linked node (`calendarEventId`, id `node:<eventId>`,
///   event `taskId` points back);
/// - feed events → homework node (`sourceEventId`, id == event id).
class NodeEventLink {
  const NodeEventLink._();

  /// Toggles an event's completion and mirrors it onto backing nodes.
  static void toggleEventDone(
    CalendarCubit calendar,
    NodeCubit nodes,
    String eventId,
  ) {
    final event = calendar.byId(eventId);
    if (event == null || !event.isTask) return;
    calendar.toggleDone(eventId);
    final updated = calendar.byId(eventId);
    if (updated == null) return;
    nodes.setDoneForEvent(
      eventId,
      done: updated.done,
      completedAt: updated.completedAt,
    );
    if (updated.done) nodes.setFailedForEvent(eventId, false);
  }

  /// Toggles a node's completion and mirrors it onto its event, if any.
  static void toggleNodeDone(
    NodeCubit nodes,
    CalendarCubit calendar,
    String nodeId,
  ) {
    final node = nodes.byId(nodeId);
    if (node == null) return;
    nodes.toggleDone(nodeId);
    final updated = nodes.byId(nodeId);
    if (updated == null) return;
    final eventId =
        updated.calendarEventId ?? updated.sourceEventId;
    if (eventId == null) return;
    final event = calendar.byId(eventId);
    if (event == null || !event.isTask) return;
    if (event.done == updated.isDone &&
        event.completedAt == updated.completedAt &&
        event.failed == (updated.status == NodeStatus.failed)) {
      return;
    }
    calendar.updateEvent(
      event.copyWith(
        done: updated.isDone,
        completedAt: updated.completedAt,
        clearCompletedAt: !updated.isDone,
        failed: updated.status == NodeStatus.failed,
      ),
    );
  }

  static void setNodeFailed(
    NodeCubit nodes,
    CalendarCubit calendar,
    String nodeId,
    bool failed,
  ) {
    final node = nodes.byId(nodeId);
    if (node == null) return;
    nodes.setStatus(
        nodeId, failed ? NodeStatus.failed : NodeStatus.open);
    final updated = nodes.byId(nodeId);
    if (updated == null) return;
    final eventId =
        updated.calendarEventId ?? updated.sourceEventId;
    if (eventId == null) return;
    final event = calendar.byId(eventId);
    if (event == null || !event.isTask) return;
    if (event.failed == failed &&
        event.done == updated.isDone &&
        event.completedAt == updated.completedAt) {
      return;
    }
    calendar.updateEvent(
      event.copyWith(
        done: updated.isDone,
        completedAt: updated.completedAt,
        clearCompletedAt: !updated.isDone,
        failed: failed,
      ),
    );
  }

  static void setEventFailed(
    CalendarCubit calendar,
    NodeCubit nodes,
    String eventId,
    bool failed,
  ) {
    final event = calendar.byId(eventId);
    if (event == null || !event.isTask) return;
    calendar.setFailed(eventId, failed);
    nodes.setFailedForEvent(eventId, failed);
    if (failed) {
      nodes.setDoneForEvent(
        eventId,
        done: false,
        completedAt: null,
      );
    }
  }

  /// Marks an event as actionable, creating its backing node.
  static void markEventAsNode(
    CalendarCubit calendar,
    NodeCubit nodes,
    String eventId,
  ) {
    final event = calendar.byId(eventId);
    if (event == null || event.isTask) return;
    if (event.isFromFeed) {
      calendar.updateEvent(event.copyWith(isTask: true));
      final marked = calendar.byId(eventId) ?? event;
      nodes.ensureNodeForFeedEvent(marked.copyWith(isTask: true));
      return;
    }
    final nodeId = nodes.upsertLinkedNodeForEvent(
      event.copyWith(isTask: true),
    );
    calendar.setTaskLink(eventId, nodeId);
  }

  /// Un-marks an event. The event is kept; backing nodes are deleted
  /// (user decision: uncheck means "not actionable anymore").
  static void unmarkEventAsNode(
    CalendarCubit calendar,
    NodeCubit nodes,
    String eventId,
  ) {
    final event = calendar.byId(eventId);
    if (event == null || !event.isTask) return;
    nodes.removeNodesForEvent(eventId);
    calendar.clearTaskLink(eventId);
  }

  /// Pushes an event's title/notes/time into its personal linked node.
  /// Homework nodes keep their originally imported values.
  static void syncEventEditToNode(
    NodeCubit nodes,
    CalendarCubit calendar,
    String eventId,
  ) {
    final event = calendar.byId(eventId);
    if (event == null || !event.isTask || event.isFromFeed) return;
    nodes.upsertLinkedNodeForEvent(event);
  }

  /// Deletes an event together with its backing nodes.
  static void deleteEventAndNodes(
    CalendarCubit calendar,
    NodeCubit nodes,
    String eventId,
  ) {
    nodes.removeNodesForEvent(eventId);
    calendar.deleteEvent(eventId);
  }
}
