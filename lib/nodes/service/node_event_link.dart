import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_progress.dart';
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

  // ── Goal assignment ─────────────────────────────────────────────────
  //
  // Assigning an event to a goal parents its backing node under the goal,
  // so the event's completion/time/money rolls into the goal's progress.
  // No stored fields are added: the DAG ([Node.parentIds]) and the
  // existing event↔node link carry everything, so old payloads load
  // untouched.

  /// True for calendar series (personal repeats, Google masters/instances).
  static bool isRepeatingEvent(PlannerEvent event) =>
      event.recurrenceRule.isNotEmpty || event.isRecurringInstance;

  /// Local grouping key for a repeating series: instances share their
  /// master's id, masters key on their own remote id. Personal repeating
  /// events are singletons (no key) and assign alone.
  static String? seriesKeyOf(PlannerEvent event) {
    if (event.seriesId != null && event.seriesId!.isNotEmpty) {
      return 'series:${event.seriesId}';
    }
    if (event.recurrenceRule.isNotEmpty &&
        event.sourceUid != null &&
        event.sourceUid!.isNotEmpty) {
      return 'series:${event.sourceUid}';
    }
    return null;
  }

  /// Every cached event in the seed's series (or just the seed when it is
  /// not part of a series). Mirrors the editor's series-wide apply, so
  /// assigning a repeating event catches every occurrence.
  static List<PlannerEvent> seriesMembers(
    CalendarCubit calendar,
    PlannerEvent seed,
  ) {
    final key = seriesKeyOf(seed);
    if (key == null) return [seed];
    return [
      for (final e in calendar.state)
        if (seriesKeyOf(e) == key) e,
    ];
  }

  /// The backing node for [eventId]: personal links, homework shadows, or
  /// the `taskId` target. Null when the event was never marked as a task.
  static Node? backingNodeFor(
    NodeCubit nodes,
    CalendarCubit calendar,
    String eventId,
  ) {
    final list = nodes.nodesForEventId(eventId);
    if (list.isNotEmpty) return list.first;
    final event = calendar.byId(eventId);
    final taskId = event?.taskId;
    if (taskId != null) return nodes.byId(taskId);
    return null;
  }

  /// Parents the backing node [nodeId] under [goalId]. Idempotent: already
  /// assigned returns null (success, nothing to do). Validation (cycles,
  /// instance rules) comes from [NodeCubit.reparent] and is returned as an
  /// error string.
  static String? assignNodeToGoal(
    NodeCubit nodes,
    String nodeId,
    String goalId,
  ) {
    final node = nodes.byId(nodeId);
    if (node == null) return 'Task not found.';
    final goal = nodes.byId(goalId);
    if (goal == null) return 'Goal not found.';
    if (nodeId == goalId) return 'An item cannot be its own parent.';
    if (goal.instanceOfId != null) {
      return 'Generated instances cannot have children of their own. '
          'Parent to the template (${goal.instanceOfId}) instead.';
    }
    if (node.parentIds.contains(goalId)) return null;
    return nodes.reparent(nodeId, [...node.parentIds, goalId]);
  }

  /// Removes [goalId] from [nodeId]'s parents. Already-removed is success.
  static String? unassignNodeFromGoal(
    NodeCubit nodes,
    String nodeId,
    String goalId,
  ) {
    final node = nodes.byId(nodeId);
    if (node == null) return 'Task not found.';
    if (!node.parentIds.contains(goalId)) return null;
    return nodes.reparent(
      nodeId,
      node.parentIds.where((p) => p != goalId).toList(),
    );
  }

  /// Assigns [eventId] (plus its whole series when [includeSeries]) to the
  /// goal [goalId]. Events not yet marked as tasks are marked first so a
  /// backing node exists. Returns the number of newly parented backing
  /// nodes plus the first error encountered, if any.
  static ({String? error, int assigned}) assignEventToGoal(
    CalendarCubit calendar,
    NodeCubit nodes,
    String eventId,
    String goalId, {
    bool includeSeries = true,
  }) {
    final seed = calendar.byId(eventId);
    if (seed == null) return (error: 'Event not found.', assigned: 0);
    if (seed.id.startsWith('node:') || seed.id.startsWith('report:')) {
      return (error: 'That tile cannot be assigned to a goal.', assigned: 0);
    }
    final goal = nodes.byId(goalId);
    if (goal == null) return (error: 'Goal not found.', assigned: 0);
    if (!isGoalNode(goal)) {
      return (
        error: 'Pick a goal from the Nodes page — '
            'imported homework cannot have children assigned.',
        assigned: 0
      );
    }
    var targets = [seed];
    if (includeSeries) {
      final members = seriesMembers(calendar, seed);
      if (members.isNotEmpty) targets = members;
    }
    var assigned = 0;
    String? firstError;
    for (final event in targets) {
      if (!event.isTask) {
        if (event.isFromFeed) {
          calendar.updateEvent(event.copyWith(isTask: true));
          final marked = calendar.byId(event.id) ?? event;
          nodes.ensureNodeForFeedEvent(marked.copyWith(isTask: true));
        } else {
          final live = calendar.byId(event.id) ?? event;
          final nodeId = nodes.upsertLinkedNodeForEvent(
            live.copyWith(isTask: true),
          );
          calendar.setTaskLink(event.id, nodeId);
        }
      } else if (event.isFromFeed) {
        nodes.ensureNodeForFeedEvent(event);
      } else {
        final live = calendar.byId(event.id) ?? event;
        final nodeId = nodes.upsertLinkedNodeForEvent(live);
        if (live.taskId == null) calendar.setTaskLink(event.id, nodeId);
      }
      final backing = backingNodeFor(nodes, calendar, event.id);
      if (backing == null) {
        firstError ??= 'Could not link “${event.subject}”.';
        continue;
      }
      if (backing.parentIds.contains(goalId)) continue;
      final error = assignNodeToGoal(nodes, backing.id, goalId);
      if (error != null) {
        firstError ??= error;
        continue;
      }
      assigned++;
    }
    if (assigned == 0 && firstError == null) {
      return (error: null, assigned: 0);
    }
    if (assigned == 0) return (error: firstError, assigned: 0);
    return (error: firstError, assigned: assigned);
  }
}
