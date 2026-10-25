import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/common/undo/revertable_hydrated_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';

import 'node_goal_assignment.dart';

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
  static void _mirrorNodeCompletion(CalendarCubit calendar, Node node) {
    final updates = <PlannerEvent>[];
    for (final event in _linkedEvents(calendar, node)) {
      if (event.done == node.isDone &&
          event.completedAt == node.completedAt &&
          event.failed == (node.status == NodeStatus.failed) &&
          event.isTask) {
        continue;
      }
      updates.add(
        event.copyWith(
          isTask: true,
          done: node.isDone,
          completedAt: node.completedAt,
          clearCompletedAt: !node.isDone,
          failed: node.status == NodeStatus.failed,
        ),
      );
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
      nodes.setStatus(nodeId, failed ? NodeStatus.failed : NodeStatus.open);
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
  /// calendar events as ONE undo step. Returns the number of
  /// nodes changed.
  static int setNodesDone(
    NodeCubit nodes,
    CalendarCubit calendar,
    Set<String> ids, {
    required bool done,
    DateTime? now,
  }) {
    if (ids.isEmpty) return 0;
    var changed = 0;
    RevertableHydratedCubit.atomic([nodes, calendar], () {
      changed = nodes.setDoneMany(ids, done: done, now: now);
      if (changed == 0) return;
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
        calUpdates.add(
          event.copyWith(
            isTask: true,
            done: node.isDone,
            completedAt: node.completedAt,
            clearCompletedAt: !node.isDone,
            failed: node.status == NodeStatus.failed,
          ),
        );
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
    });
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
    var removed = 0;
    RevertableHydratedCubit.atomic([nodes, calendar], () {
      final beforeNodes = nodes.state;
      removed = nodes.deleteNodes(ids);
      if (removed == 0) return;
      final remainingIds = nodes.state.map((n) => n.id).toSet();
      final removedIds = beforeNodes
          .map((n) => n.id)
          .where((id) => !remainingIds.contains(id))
          .toSet();
      final eventIds = <String>{};
      for (final node in beforeNodes) {
        if (!removedIds.contains(node.id)) continue;
        for (final eventId in [node.calendarEventId, node.sourceEventId]) {
          if (eventId != null) eventIds.add(eventId);
        }
      }
      // Events seeded from any deleted task point at it through `taskId`.
      // They are kept and unlinked, never deleted — same as directly linked
      // events below.
      for (final event in calendar.state) {
        if (event.taskId != null && removedIds.contains(event.taskId)) {
          eventIds.add(event.id);
        }
      }
      final calUpdates = <PlannerEvent>[];
      for (final eventId in eventIds) {
        final event = calendar.byId(eventId);
        if (event == null) continue;
        if (!event.isTask && event.taskId == null && !event.done) continue;
        calUpdates.add(
          event.copyWith(
            isTask: false,
            clearTaskId: true,
            done: false,
            clearCompletedAt: true,
          ),
        );
      }
      if (calUpdates.isNotEmpty) calendar.updateEvents(calUpdates);
    });
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
  /// into the same record, so undo restores both. A task-seeded standalone
  /// node survives, but its personal event link is cleared in that record.
  static void deleteEventAndNodes(
    CalendarCubit calendar,
    NodeCubit nodes,
    PlannerEvent event,
  ) {
    RevertableHydratedCubit.atomic([calendar, nodes], () {
      nodes.removeNodesForEvent(event.id);
      if (event.taskId != null) nodes.clearCalendarEvent(event.taskId!);
      nodes.clearCalendarEventForEvent(event.id);
      calendar.deleteEvent(event.id);
    });
  }

  // Public facade retained for existing calendar and goal callers.
  static bool isRepeatingEvent(PlannerEvent e) =>
      NodeGoalAssignment.isRepeatingEvent(e);
  static String? seriesKeyOf(PlannerEvent e) =>
      NodeGoalAssignment.seriesKeyOf(e);
  static List<PlannerEvent> seriesMembers(CalendarCubit c, PlannerEvent e) =>
      NodeGoalAssignment.seriesMembers(c, e);
  static DateTime startOfDay(DateTime now) =>
      NodeGoalAssignment.startOfDay(now);
  static bool isFutureOccurrence(PlannerEvent e, DateTime now) =>
      NodeGoalAssignment.isFutureOccurrence(e, now);
  static List<PlannerEvent> futureSeriesMembers(
    CalendarCubit c,
    PlannerEvent e, {
    DateTime? now,
  }) => NodeGoalAssignment.futureSeriesMembers(c, e, now: now);
  static Node? backingNodeFor(NodeCubit n, CalendarCubit c, String id) =>
      NodeGoalAssignment.backingNodeFor(n, c, id);
  static String? assignNodeToGoal(NodeCubit n, String id, String goal) =>
      NodeGoalAssignment.assignNodeToGoal(n, id, goal);
  static String? unassignNodeFromGoal(NodeCubit n, String id, String goal) =>
      NodeGoalAssignment.unassignNodeFromGoal(n, id, goal);
  static ({String? error, int removed}) unassignEventFromGoal(
    CalendarCubit c,
    NodeCubit n,
    String id,
    String goal, {
    bool includeSeries = true,
    DateTime? now,
  }) => NodeGoalAssignment.unassignEventFromGoal(
    c,
    n,
    id,
    goal,
    includeSeries: includeSeries,
    now: now,
  );
  static ({String? error, int assigned}) assignEventToGoal(
    CalendarCubit c,
    NodeCubit n,
    String id,
    String goal, {
    bool includeSeries = true,
    DateTime? now,
  }) => NodeGoalAssignment.assignEventToGoal(
    c,
    n,
    id,
    goal,
    includeSeries: includeSeries,
    now: now,
  );

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
    bool allowCompleted = false,
  }) {
    final node = nodes.byId(nodeId);
    if (node == null || node.isTracking) return;
    if (node.isDone && !allowCompleted) return;
    final at = now ?? DateTime.now();
    RevertableHydratedCubit.atomic([nodes, calendar], () {
      final activeEvent = calendar.activeTrackingEvent;
      if (activeEvent != null) {
        calendar.stopTracking(activeEvent.id, now: at);
      }
      nodes.startTracking(nodeId, now: at, allowCompleted: allowCompleted);
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
    bool allowCompleted = false,
  }) {
    final event = calendar.byId(eventId);
    if (event == null || event.allDay || event.isTracking) return;
    final backing = event.isTask
        ? backingNodeFor(nodes, calendar, eventId)
        : null;
    if (backing != null) {
      startNodeTracking(
        nodes,
        calendar,
        backing.id,
        now: now,
        allowCompleted: allowCompleted,
      );
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
      if (wasTracking && settled.recordedSessions.isNotEmpty) {
        calendar.updateEvents([
          for (final event in linked)
            _eventWithSessions(
              event,
              settled.recordedSessions,
            ).copyWith(clearTimerStartedAt: true),
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
    final backing = event.isTask
        ? backingNodeFor(nodes, calendar, eventId)
        : null;
    if (backing != null && backing.isTracking) {
      stopNodeTrackingAligned(nodes, calendar, backing.id, now: now);
      return;
    }
    final at = now ?? DateTime.now();
    RevertableHydratedCubit.atomic([nodes, calendar], () {
      calendar.stopTracking(eventId, now: at);
      final stopped = calendar.byId(eventId) ?? event;
      if (backing != null && stopped.recordedSessions.isNotEmpty) {
        // Merge rather than replace: the node may already hold sessions
        // recorded while the event ran on its own.
        var merged = nodes.byId(backing.id) ?? backing;
        for (final session in stopped.recordedSessions) {
          merged = merged.copyWith(
            sessions: withSession(merged.recordedSessions, session),
          );
        }
        nodes.setSessions(backing.id, merged.recordedSessions);
      }
    });
  }

  /// Copies a session list onto an event and refreshes its aggregate span.
  static PlannerEvent _eventWithSessions(
    PlannerEvent event,
    List<TimeSession> sessions,
  ) {
    final span = sessionSpan(sessions);
    return event.copyWith(
      sessions: sessions,
      actualStart: span?.start,
      clearActualStart: span == null,
      actualEnd: span?.end,
      clearActualEnd: span == null,
    );
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
  static List<PlannerEvent> _linkedEvents(CalendarCubit calendar, Node node) {
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
