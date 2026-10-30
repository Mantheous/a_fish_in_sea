import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/common/undo/revertable_hydrated_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';

/// Coordinates persisted fields shared by calendar events and their task
/// nodes. Kept separate from link actions so these idempotent save paths can
/// be tested without the calendar widgets.
class NodeEventSync {
  const NodeEventSync._();

  /// Reapplies a saved completion state without interpreting it as a toggle.
  static void setEventDone(
    CalendarCubit calendar,
    NodeCubit nodes,
    String eventId, {
    required bool done,
    DateTime? completedAt,
  }) {
    final event = calendar.byId(eventId);
    if (event == null || !event.isTask) return;
    final at = done
        ? (completedAt ?? event.completedAt ?? DateTime.now())
        : null;
    RevertableHydratedCubit.atomic([calendar, nodes], () {
      final current = calendar.byId(eventId);
      if (current == null) return;
      if (current.done != done || current.completedAt != at) {
        calendar.updateEvent(
          current.copyWith(
            done: done,
            completedAt: at,
            clearCompletedAt: !done,
          ),
        );
      }
      nodes.setDoneForEvent(
        eventId,
        done: done,
        completedAt: at,
        taskId: current.taskId,
      );
      if (done) {
        nodes.setFailedForEvent(eventId, false, taskId: current.taskId);
      }
    });
  }

  /// Applies a calendar drag/resize to both the event and its backing task
  /// schedule as one undoable update. Homework due dates are independent of
  /// the calendar block and are retained; personal task due dates follow
  /// the event's start, matching [NodeCubit.upsertLinkedNodeForEvent].
  static void rescheduleLinkedEvent(
    CalendarCubit calendar,
    NodeCubit nodes,
    PlannerEvent updated,
  ) {
    final current = calendar.byId(updated.id);
    if (current == null) return;
    final backing = NodeEventLink.backingNodeFor(nodes, calendar, updated.id);
    RevertableHydratedCubit.atomic([calendar, nodes], () {
      calendar.updateEvent(updated);
      if (backing == null) return;
      final schedule = backing.schedule;
      nodes.updateNode(
        backing.copyWith(
          schedule: ScheduleFacet(
            due: backing.sourceEventId == null
                ? updated.start
                : (schedule?.due ?? updated.start),
            start: updated.start,
            end: updated.end,
            allDay: updated.allDay,
            isFixed: schedule?.isFixed ?? false,
          ),
        ),
      );
    });
  }

  /// Moves a running task timer's start and mirrors it onto linked events
  /// that are independently recording. Task-event pairs normally record on
  /// the node, so most linked events carry no timer; those are left alone
  /// rather than accidentally started.
  static void setNodeTimerStart(
    NodeCubit nodes,
    CalendarCubit calendar,
    String nodeId,
    DateTime start, {
    DateTime? now,
  }) {
    final node = nodes.byId(nodeId);
    if (node == null || !node.isTracking) return;
    RevertableHydratedCubit.atomic([nodes, calendar], () {
      nodes.setTimerStart(nodeId, start, now: now);
      final saved = nodes.byId(nodeId);
      final applied = saved?.timerStartedAt;
      if (saved == null || applied == null) return;
      final updates = [
        for (final event in _linkedEvents(calendar, saved))
          if (event.isTracking && event.timerStartedAt != applied)
            event.copyWith(timerStartedAt: applied),
      ];
      if (updates.isNotEmpty) calendar.updateEvents(updates);
    });
  }

  /// Mirrors a manual timer correction from a task to every linked event,
  /// keeping the event-side report cache aligned with the task record.
  static bool setNodeReported(
    NodeCubit nodes,
    CalendarCubit calendar,
    String nodeId,
    DateTime start,
    DateTime end,
  ) {
    final node = nodes.byId(nodeId);
    if (node == null || node.recordedSessions.length > 1) return false;
    final safeEnd = end.isAfter(start)
        ? end
        : start.add(const Duration(minutes: 1));
    final session = node.recordedSessions.singleOrNull;
    if (session?.start == start && session?.end == safeEnd) return false;
    RevertableHydratedCubit.atomic([nodes, calendar], () {
      nodes.setReported(nodeId, start, safeEnd);
      final saved = nodes.byId(nodeId);
      if (saved == null) return;
      _mirrorSessions(calendar, saved, replace: true);
    });
    return nodes.byId(nodeId) != node;
  }

  /// Moves one recorded run on the task and mirrors the task's whole list
  /// onto every linked event.
  static bool setNodeSession(
    NodeCubit nodes,
    CalendarCubit calendar,
    String nodeId,
    String sessionId,
    DateTime start,
    DateTime end,
  ) {
    final node = nodes.byId(nodeId);
    if (node == null) return false;
    final session = sessionById(node.recordedSessions, sessionId);
    if (session == null) return false;
    final safeEnd = end.isAfter(start)
        ? end
        : start.add(const Duration(minutes: 1));
    RevertableHydratedCubit.atomic([nodes, calendar], () {
      nodes.updateSession(nodeId, sessionId, start, safeEnd);
      final saved = nodes.byId(nodeId);
      if (saved == null) return;
      _mirrorSessions(calendar, saved);
    });
    return nodes.byId(nodeId) != node;
  }

  /// Deletes one recorded run on the task and from every linked event,
  /// leaving any other runs intact.
  static void removeNodeSession(
    NodeCubit nodes,
    CalendarCubit calendar,
    String nodeId,
    String sessionId,
  ) {
    if (nodes.byId(nodeId) == null) return;
    RevertableHydratedCubit.atomic([nodes, calendar], () {
      nodes.removeSession(nodeId, sessionId);
      final saved = nodes.byId(nodeId);
      if (saved == null) return;
      _mirrorSessions(calendar, saved, removeSessionId: sessionId);
    });
  }

  /// Transfers the task's chunk and its calendar mirrors as one undo step.
  /// Only the moved session ids leave the source events; independent runs
  /// on either side remain intact.
  static void reassignNodeChunk(
    NodeCubit nodes,
    CalendarCubit calendar,
    String fromId,
    String toId,
  ) {
    final from = nodes.byId(fromId);
    final to = nodes.byId(toId);
    if (fromId == toId || from == null || to == null) return;
    if (!from.hasReported && !from.isTracking) return;
    final movedIds = from.recordedSessions.map((s) => s.id).toSet();
    RevertableHydratedCubit.atomic([nodes, calendar], () {
      nodes.reassignChunk(fromId, toId);
      final updates = [
        for (final event in _linkedEvents(calendar, from))
          _eventWithSessions(
            event,
            event.recordedSessions
                .where((s) => !movedIds.contains(s.id))
                .toList(),
            replace: true,
            clearTimerStartedAt: false,
          ),
      ];
      if (updates.isNotEmpty) calendar.updateEvents(updates);
      final saved = nodes.byId(toId)!;
      final destinationUpdates = [
        for (final event in _linkedEvents(calendar, saved))
          _eventWithSessions(
            event,
            saved.recordedSessions,
            clearTimerStartedAt: false,
          ),
      ];
      if (destinationUpdates.isNotEmpty) {
        calendar.updateEvents(destinationUpdates);
      }
    });
  }

  static void _mirrorSessions(
    CalendarCubit calendar,
    Node saved, {
    String? removeSessionId,
    bool replace = false,
  }) {
    final updates = [
      for (final event in _linkedEvents(calendar, saved))
        _eventWithSessions(
          event,
          saved.recordedSessions,
          removeSessionId: removeSessionId,
          replace: replace,
        ),
    ];
    if (updates.isNotEmpty) calendar.updateEvents(updates);
  }

  /// Unions the task's runs into the event's own list instead of replacing
  /// it: a run recorded directly on the event (for example a failed stop
  /// that never reached the task) must survive a task-side edit. A manual
  /// report correction ([replace]) intentionally rewrites the mirror.
  static PlannerEvent _eventWithSessions(
    PlannerEvent event,
    List<TimeSession> sessions, {
    String? removeSessionId,
    bool replace = false,
    bool clearTimerStartedAt = true,
  }) {
    var combined = replace ? <TimeSession>[] : event.recordedSessions;
    if (removeSessionId != null) {
      combined = withoutSession(combined, removeSessionId);
    }
    for (final session in sessions) {
      combined = withSession(combined, session);
    }
    final span = sessionSpan(combined);
    return event.copyWith(
      sessions: combined,
      actualStart: span?.start,
      clearActualStart: span == null,
      actualEnd: span?.end,
      clearActualEnd: span == null,
      clearTimerStartedAt: clearTimerStartedAt,
    );
  }

  /// Clears the task's report and the same cached interval on every linked
  /// event, so Plan + Report cannot keep displaying a stale block.
  static void clearNodeReported(
    NodeCubit nodes,
    CalendarCubit calendar,
    String nodeId,
  ) {
    final node = nodes.byId(nodeId);
    if (node == null) return;
    RevertableHydratedCubit.atomic([nodes, calendar], () {
      nodes.clearReported(nodeId);
      final saved = nodes.byId(nodeId);
      if (saved == null) return;
      final updates = [
        for (final event in _linkedEvents(calendar, saved))
          if (event.actualStart != null ||
              event.actualEnd != null ||
              event.isTracking)
            event.copyWith(
              sessions: const [],
              clearActualStart: true,
              clearActualEnd: true,
              clearTimerStartedAt: true,
            ),
      ];
      if (updates.isNotEmpty) calendar.updateEvents(updates);
    });
  }

  static List<PlannerEvent> _linkedEvents(CalendarCubit calendar, Node node) {
    final ids = <String>{};
    if (node.calendarEventId != null) ids.add(node.calendarEventId!);
    if (node.sourceEventId != null) ids.add(node.sourceEventId!);
    for (final event in calendar.state) {
      if (event.taskId == node.id) ids.add(event.id);
    }
    final linked = <PlannerEvent>[];
    for (final id in ids) {
      final event = calendar.byId(id);
      if (event != null) linked.add(event);
    }
    return linked;
  }
}
