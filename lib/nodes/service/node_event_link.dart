import 'package:a_fish_in_sea/common/undo/revertable_hydrated_cubit.dart';
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
  /// One user gesture = one undo step (see [RevertableHydratedCubit.atomic]).
  static void toggleEventDone(
    CalendarCubit calendar,
    NodeCubit nodes,
    String eventId,
  ) {
    final event = calendar.byId(eventId);
    if (event == null || !event.isTask) return;
    RevertableHydratedCubit.atomic([calendar, nodes], () {
      calendar.toggleDone(eventId);
      final updated = calendar.byId(eventId);
      if (updated == null) return;
      nodes.setDoneForEvent(
        eventId,
        done: updated.done,
        completedAt: updated.completedAt,
      );
      if (updated.done) nodes.setFailedForEvent(eventId, false);
    });
  }

  /// Toggles a node's completion and mirrors it onto its event, if any.
  /// One user gesture = one undo step.
  static void toggleNodeDone(
    NodeCubit nodes,
    CalendarCubit calendar,
    String nodeId,
  ) {
    final node = nodes.byId(nodeId);
    if (node == null) return;
    RevertableHydratedCubit.atomic([nodes, calendar], () {
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
    });
  }

  static void setNodeFailed(
    NodeCubit nodes,
    CalendarCubit calendar,
    String nodeId,
    bool failed,
  ) {
    final node = nodes.byId(nodeId);
    if (node == null) return;
    RevertableHydratedCubit.atomic([nodes, calendar], () {
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
    });
  }

  static void setEventFailed(
    CalendarCubit calendar,
    NodeCubit nodes,
    String eventId,
    bool failed,
  ) {
    final event = calendar.byId(eventId);
    if (event == null || !event.isTask) return;
    RevertableHydratedCubit.atomic([calendar, nodes], () {
      calendar.setFailed(eventId, failed);
      nodes.setFailedForEvent(eventId, failed);
      if (failed) {
        nodes.setDoneForEvent(
          eventId,
          done: false,
          completedAt: null,
        );
      }
    });
  }

  /// Marks an event as actionable, creating its backing node.
  static void markEventAsNode(
    CalendarCubit calendar,
    NodeCubit nodes,
    String eventId,
  ) {
    final event = calendar.byId(eventId);
    if (event == null || event.isTask) return;
    RevertableHydratedCubit.atomic([calendar, nodes], () {
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
    });
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
    RevertableHydratedCubit.atomic([calendar, nodes], () {
      nodes.removeNodesForEvent(eventId);
      calendar.clearTaskLink(eventId);
    });
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
  /// One user gesture = one undo step (the silent node removal is folded
  /// into the same record, so undo restores both).
  static void deleteEventAndNodes(
    CalendarCubit calendar,
    NodeCubit nodes,
    String eventId,
  ) {
    RevertableHydratedCubit.atomic([calendar, nodes], () {
      nodes.removeNodesForEvent(eventId);
      calendar.deleteEvent(eventId);
    });
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
  ///
  /// Batched into at most four emits (one per phase below): the old
  /// per-member loop snapshotted the whole store, rebuilt, persisted, and
  /// recorded an undo entry per occurrence — hundreds of full-store
  /// snapshots that freeze then kill the tab on large stores.
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
    // Phase 1: personal backing nodes, batched. Non-task members are
    // marked first via the isTask copy, mirroring the single-write lookup
    // order (taskId link, calendar-event link, create).
    final personalInputs = <PlannerEvent>[];
    for (final event in targets) {
      if (event.isFromFeed) continue;
      final live = calendar.byId(event.id) ?? event;
      personalInputs.add(event.isTask ? live : live.copyWith(isTask: true));
    }
    final linkedIds = nodes.upsertLinkedNodesForEvents(personalInputs);
    // Phase 2: calendar marks + task links, batched. Mirrors
    // [CalendarCubit.setTaskLink]'s skip rule (same taskId and already a
    // task means nothing to do).
    final calUpdates = <PlannerEvent>[];
    for (final event in targets) {
      final live = calendar.byId(event.id) ?? event;
      if (!event.isTask) {
        if (event.isFromFeed) {
          if (!live.isTask) calUpdates.add(live.copyWith(isTask: true));
        } else {
          final nodeId = linkedIds[event.id];
          if (nodeId != null &&
              !(live.taskId == nodeId && live.isTask)) {
            calUpdates.add(live.copyWith(isTask: true, taskId: nodeId));
          }
        }
      } else if (!event.isFromFeed && live.taskId == null) {
        final nodeId = linkedIds[event.id];
        if (nodeId != null) {
          calUpdates.add(live.copyWith(isTask: true, taskId: nodeId));
        }
      }
    }
    calendar.updateEvents(calUpdates);
    // Phase 3: feed backing shadows, batched.
    final feedInputs = <PlannerEvent>[];
    for (final event in targets) {
      if (!event.isFromFeed) continue;
      final live = calendar.byId(event.id) ?? event;
      feedInputs.add(event.isTask ? live : live.copyWith(isTask: true));
    }
    nodes.ensureNodesForFeedEvents(feedInputs);
    // Phase 4: parent every backing under the goal, batched. Same guards
    // as [assignNodeToGoal], in the same order (self, generated-goal,
    // already-parented); cycle/relation errors come back from the batch
    // write's validation, which runs the same validators.
    var assigned = 0;
    String? firstError;
    final toParent = <String, Node>{};
    for (final event in targets) {
      final backing = backingNodeFor(nodes, calendar, event.id);
      if (backing == null) {
        firstError ??= 'Could not link “${event.subject}”.';
        continue;
      }
      if (backing.id == goalId) {
        firstError ??= 'An item cannot be its own parent.';
        continue;
      }
      if (goal.instanceOfId != null) {
        firstError ??= 'Generated instances cannot have children of their '
            'own. Parent to the template (${goal.instanceOfId}) instead.';
        continue;
      }
      if (backing.parentIds.contains(goalId)) continue;
      toParent.putIfAbsent(
        backing.id,
        () => backing.copyWith(parentIds: [...backing.parentIds, goalId]),
      );
    }
    final writeErrors =
        nodes.writeNodes(upserts: toParent.values.toList());
    for (final entry in toParent.entries) {
      final err = writeErrors[entry.key];
      if (err != null) {
        firstError ??= err;
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
