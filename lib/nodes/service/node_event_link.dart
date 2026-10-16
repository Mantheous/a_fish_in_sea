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
  /// The event's `taskId` target mirrors too, so nodes reachable only
  /// through it (no `calendarEventId` back-link yet) stay in sync.
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
        taskId: updated.taskId,
      );
      if (updated.done) {
        nodes.setFailedForEvent(eventId, false, taskId: updated.taskId);
      }
    });
  }

  /// Toggles a node's completion and mirrors it onto its event, if any.
  /// One user gesture = one undo step. Events pointing at the node through
  /// `taskId` mirror too, so a task-seeded event cannot keep a stale
  /// `done: false` that the next calendar save writes back onto the node.
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
      _mirrorNodeCompletion(calendar, updated);
    });
  }

  /// Writes [node]'s completion onto every linked event: the direct
  /// `calendarEventId`/`sourceEventId` target plus every event whose
  /// `taskId` points at the node. Skips events already in agreement so the
  /// mirror stays a no-op emit when nothing changed.
  ///
  /// Linked events are included even when their `isTask` flag is off: a
  /// surviving link means the event is still the node's schedule (the
  /// editor supports saving a task-seeded block as a plain event without
  /// deleting the task), and leaving it open desyncs the calendar from
  /// the Tasks list. Mirroring heals `isTask` back on so the tile reads
  /// as done and later calendar toggles route through the backing node.
  static void _mirrorNodeCompletion(
    CalendarCubit calendar,
    Node node,
  ) {
    final updates = <PlannerEvent>[];
    for (final event in _linkedEvents(calendar, node)) {
      if (event.done == node.isDone &&
          event.completedAt == node.completedAt &&
          event.failed == (node.status == NodeStatus.failed) &&
          event.isTask) {
        continue;
      }
      updates.add(event.copyWith(
        isTask: true,
        done: node.isDone,
        completedAt: node.completedAt,
        clearCompletedAt: !node.isDone,
        failed: node.status == NodeStatus.failed,
      ));
    }
    if (updates.isNotEmpty) calendar.updateEvents(updates);
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
      _mirrorNodeCompletion(calendar, updated);
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
      nodes.setFailedForEvent(eventId, failed, taskId: event.taskId);
      if (failed) {
        nodes.setDoneForEvent(
          eventId,
          done: false,
          completedAt: null,
          taskId: event.taskId,
        );
      }
    });
  }

  /// Marks many nodes done/open and mirrors completion onto their linked
  /// calendar events, batched into two emits (one per store) so a bulk
  /// check-off stays a single undo step per store. Returns the number of
  /// nodes changed.
  static int setNodesDone(
    NodeCubit nodes,
    CalendarCubit calendar,
    Set<String> ids, {
    required bool done,
    DateTime? now,
  }) {
    if (ids.isEmpty) return 0;
    final changed = nodes.setDoneMany(ids, done: done, now: now);
    if (changed == 0) return 0;
    // Reverse `taskId` index built once: events seeded from a task point
    // at it without a `calendarEventId` back-link, and must mirror too.
    final byTaskId = <String, List<PlannerEvent>>{};
    for (final event in calendar.state) {
      final taskId = event.taskId;
      if (taskId != null && ids.contains(taskId)) {
        (byTaskId[taskId] ??= []).add(event);
      }
    }
    final seen = <String>{};
    final calUpdates = <PlannerEvent>[];
    void consider(PlannerEvent event, Node node) {
      if (!seen.add(event.id)) return;
      if (event.done == node.isDone &&
          event.completedAt == node.completedAt &&
          event.failed == (node.status == NodeStatus.failed) &&
          event.isTask) {
        return;
      }
      calUpdates.add(event.copyWith(
        isTask: true,
        done: node.isDone,
        completedAt: node.completedAt,
        clearCompletedAt: !node.isDone,
        failed: node.status == NodeStatus.failed,
      ));
    }

    for (final id in ids) {
      final node = nodes.byId(id);
      if (node == null) continue;
      for (final eventId in [node.calendarEventId, node.sourceEventId]) {
        if (eventId == null) continue;
        final event = calendar.byId(eventId);
        if (event != null) consider(event, node);
      }
      for (final event in byTaskId[id] ?? const <PlannerEvent>[]) {
        consider(event, node);
      }
    }
    if (calUpdates.isNotEmpty) calendar.updateEvents(calUpdates);
    return changed;
  }

  /// Deletes many nodes and clears their calendar task links, batched
  /// into two emits (one per store). Mirrors the single-delete behaviour
  /// ([NodeCubit.deleteNode] + [CalendarCubit.clearTaskLink]): events are
  /// kept and unlinked, never deleted. Returns the number removed.
  static int deleteNodesAndUnlink(
    NodeCubit nodes,
    CalendarCubit calendar,
    Set<String> ids,
  ) {
    if (ids.isEmpty) return 0;
    final eventIds = <String>{};
    for (final id in ids) {
      final node = nodes.byId(id);
      if (node == null) continue;
      for (final eventId in [node.calendarEventId, node.sourceEventId]) {
        if (eventId != null) eventIds.add(eventId);
      }
    }
    // Events seeded from a deleted task point at it through `taskId`.
    // They are kept and unlinked, never deleted — same as directly linked
    // events below.
    final reverseIds = <String>{};
    for (final event in calendar.state) {
      final taskId = event.taskId;
      if (taskId != null && ids.contains(taskId)) {
        reverseIds.add(event.id);
      }
    }
    final removed = nodes.deleteNodes(ids);
    if (removed == 0) return 0;
    final calUpdates = <PlannerEvent>[];
    for (final eventId in {...eventIds, ...reverseIds}) {
      final event = calendar.byId(eventId);
      if (event == null) continue;
      if (!event.isTask && event.taskId == null && !event.done) continue;
      calUpdates.add(event.copyWith(
        isTask: false,
        clearTaskId: true,
        done: false,
        clearCompletedAt: true,
      ));
    }
    if (calUpdates.isNotEmpty) calendar.updateEvents(calUpdates);
    return removed;
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

  /// Start of [now]'s calendar day (local). Series tasking treats anything
  /// starting today or later as "future"; anything before is past.
  static DateTime startOfDay(DateTime now) =>
      DateTime(now.year, now.month, now.day);

  /// True when [event]'s occurrence has not yet passed: it starts on or
  /// after [now]'s calendar day. Task due dates land on the occurrence's
  /// own start day, so this matches the Tasks page's own past/today split
  /// (overdue = due before the start of today).
  static bool isFutureOccurrence(PlannerEvent event, DateTime now) =>
      !event.start.isBefore(startOfDay(now));

  /// The series members that become tasks when a repeating event is marked
  /// as a task: every future occurrence plus the seed itself. The seed is
  /// always included so explicitly picking a past occurrence still acts on
  /// it; the rest of the past is skipped so marking a series that has been
  /// repeating for a while doesn't spam the Tasks list with overdue todos
  /// for every past occurrence.
  static List<PlannerEvent> futureSeriesMembers(
    CalendarCubit calendar,
    PlannerEvent seed, {
    DateTime? now,
  }) {
    final members = seriesMembers(calendar, seed);
    if (members.length <= 1) return members;
    final at = now ?? DateTime.now();
    return [
      for (final e in members)
        if (e.id == seed.id || isFutureOccurrence(e, at)) e,
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

  /// Removes [goalId] from the backing node(s) of [eventId]. With
  /// [includeSeries] the removal covers the seed plus its future series
  /// members (mirroring [assignEventToGoal]'s targets); otherwise only
  /// this occurrence. Batched into one emit. Returns the number of
  /// backing nodes actually unparented plus the first error, if any.
  static ({String? error, int removed}) unassignEventFromGoal(
    CalendarCubit calendar,
    NodeCubit nodes,
    String eventId,
    String goalId, {
    bool includeSeries = true,
    DateTime? now,
  }) {
    final seed = calendar.byId(eventId);
    if (seed == null) return (error: 'Event not found.', removed: 0);
    var targets = [seed];
    if (includeSeries) {
      final members = futureSeriesMembers(calendar, seed, now: now);
      if (members.isNotEmpty) targets = members;
    }
    final toUnparent = <String, Node>{};
    for (final event in targets) {
      final backing = backingNodeFor(nodes, calendar, event.id);
      if (backing == null) continue;
      if (!backing.parentIds.contains(goalId)) continue;
      toUnparent.putIfAbsent(
        backing.id,
        () => backing.copyWith(
          parentIds:
              backing.parentIds.where((p) => p != goalId).toList(),
        ),
      );
    }
    if (toUnparent.isEmpty) return (error: null, removed: 0);
    final writeErrors =
        nodes.writeNodes(upserts: toUnparent.values.toList());
    var removed = 0;
    String? firstError;
    for (final entry in toUnparent.entries) {
      final err = writeErrors[entry.key];
      if (err != null) {
        firstError ??= err;
        continue;
      }
      removed++;
    }
    if (removed == 0) return (error: firstError, removed: 0);
    return (error: firstError, removed: removed);
  }

  /// Assigns [eventId] (plus its future series members when
  /// [includeSeries]) to the goal [goalId]. Events not yet marked as tasks
  /// are marked first so a backing node exists. Past occurrences are
  /// skipped (the seed itself is always included): assigning a series that
  /// has been repeating for a while must not flood the Tasks list with an
  /// overdue todo per past occurrence. Returns the number of newly
  /// parented backing nodes plus the first error encountered, if any.
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
    DateTime? now,
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
      final members = futureSeriesMembers(calendar, seed, now: now);
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

  // ── Time tracking (single path for tasks) ──────────────────────────
  //
  // A task-event pair records one session, not two: the backing node owns
  // the timer and the event mirrors it for display. Every start/stop below
  // runs as one undo step across both cubits and keeps a single active
  // timer across both stores (Toggl-style: starting one saves whatever
  // else was recording). Plain events without a backing node record on
  // the event itself, exactly as before.

  /// Starts [nodeId]'s timer, first saving + stopping any running event
  /// timer so the two stores never record at once.
  static void startNodeTracking(
    NodeCubit nodes,
    CalendarCubit calendar,
    String nodeId, {
    DateTime? now,
  }) {
    final node = nodes.byId(nodeId);
    if (node == null || node.isDone || node.isTracking) return;
    final at = now ?? DateTime.now();
    RevertableHydratedCubit.atomic([nodes, calendar], () {
      final activeEvent = calendar.activeTrackingEvent;
      if (activeEvent != null) {
        calendar.stopTracking(activeEvent.id, now: at);
      }
      nodes.startTracking(nodeId, now: at);
    });
  }

  /// Starts [eventId]'s timer. Task-events with a backing node record on
  /// the node ([startNodeTracking]); plain events record on the event,
  /// first saving + stopping any running node timer.
  static void startEventTracking(
    NodeCubit nodes,
    CalendarCubit calendar,
    String eventId, {
    DateTime? now,
  }) {
    final event = calendar.byId(eventId);
    if (event == null || event.allDay || event.isTracking) return;
    final backing =
        event.isTask ? backingNodeFor(nodes, calendar, eventId) : null;
    if (backing != null) {
      startNodeTracking(nodes, calendar, backing.id, now: now);
      return;
    }
    final at = now ?? DateTime.now();
    RevertableHydratedCubit.atomic([nodes, calendar], () {
      final activeId = nodes.activeTrackingId;
      if (activeId != null) nodes.stopTracking(activeId, now: at);
      calendar.startTracking(eventId, now: at);
    });
  }

  /// Stops [nodeId]'s timer and mirrors the reported interval onto every
  /// linked task-event (clearing their timers). When the node was idle
  /// but a linked event is still recording, the event's own interval is
  /// saved instead so the session is never lost.
  static void stopNodeTrackingAligned(
    NodeCubit nodes,
    CalendarCubit calendar,
    String nodeId, {
    DateTime? now,
  }) {
    final node = nodes.byId(nodeId);
    if (node == null) return;
    final at = now ?? DateTime.now();
    RevertableHydratedCubit.atomic([nodes, calendar], () {
      final wasTracking = node.isTracking;
      if (wasTracking) nodes.stopTracking(nodeId, now: at);
      final settled = nodes.byId(nodeId) ?? node;
      final linked = _linkedTaskEvents(calendar, settled);
      if (linked.isEmpty) return;
      if (wasTracking &&
          settled.actualStart != null &&
          settled.actualEnd != null) {
        calendar.updateEvents([
          for (final event in linked)
            event.copyWith(
              actualStart: settled.actualStart,
              actualEnd: settled.actualEnd,
              clearTimerStartedAt: true,
            ),
        ]);
        return;
      }
      for (final event in linked) {
        if (event.isTracking) calendar.stopTracking(event.id, now: at);
      }
    });
  }

  /// Stops [eventId]'s timer. Task-events with a tracking backing node
  /// stop through the node ([stopNodeTrackingAligned], which mirrors back
  /// onto the event); a divergent event-only run on a linked pair is
  /// copied onto the idle node so reports (which prefer the node) keep
  /// the session. Plain events stop on the event itself.
  static void stopEventTrackingAligned(
    NodeCubit nodes,
    CalendarCubit calendar,
    String eventId, {
    DateTime? now,
  }) {
    final event = calendar.byId(eventId);
    if (event == null || !event.isTracking) return;
    final backing =
        event.isTask ? backingNodeFor(nodes, calendar, eventId) : null;
    if (backing != null && backing.isTracking) {
      stopNodeTrackingAligned(nodes, calendar, backing.id, now: now);
      return;
    }
    final at = now ?? DateTime.now();
    RevertableHydratedCubit.atomic([nodes, calendar], () {
      calendar.stopTracking(eventId, now: at);
      final stopped = calendar.byId(eventId) ?? event;
      if (backing != null &&
          stopped.actualStart != null &&
          stopped.actualEnd != null) {
        nodes.setReported(
          backing.id,
          stopped.actualStart!,
          stopped.actualEnd!,
        );
      }
    });
  }

  /// Every task-event linked to [node]: the direct `calendarEventId` /
  /// `sourceEventId` targets plus events whose `taskId` points at it.
  /// Used by the time-tracking paths, where only actionable task-events
  /// carry timers.
  static List<PlannerEvent> _linkedTaskEvents(
    CalendarCubit calendar,
    Node node,
  ) {
    final seen = <String>{};
    final out = <PlannerEvent>[];
    for (final eventId in [node.calendarEventId, node.sourceEventId]) {
      if (eventId == null || !seen.add(eventId)) continue;
      final event = calendar.byId(eventId);
      if (event != null && event.isTask) out.add(event);
    }
    for (final event in calendar.state) {
      if (event.isTask && event.taskId == node.id && seen.add(event.id)) {
        out.add(event);
      }
    }
    return out;
  }

  /// Every event linked to [node], including ones whose `isTask` flag is
  /// off. A surviving link (direct id or `taskId`) means the event is
  /// still the node's schedule, so completion mirrors onto it (healing
  /// `isTask`) instead of silently desyncing the calendar tile.
  static List<PlannerEvent> _linkedEvents(
    CalendarCubit calendar,
    Node node,
  ) {
    final seen = <String>{};
    final out = <PlannerEvent>[];
    for (final eventId in [node.calendarEventId, node.sourceEventId]) {
      if (eventId == null || !seen.add(eventId)) continue;
      final event = calendar.byId(eventId);
      if (event != null) out.add(event);
    }
    for (final event in calendar.state) {
      if (event.taskId == node.id && seen.add(event.id)) {
        out.add(event);
      }
    }
    return out;
  }
}
