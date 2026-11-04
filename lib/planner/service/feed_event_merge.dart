import '../model/planner_event.dart';
import '../model/task_assignee.dart';

/// Keeps user-owned metadata when a fresh feed copy replaces an event.
PlannerEvent preserveLocalFeedMetadata(
  PlannerEvent fresh,
  PlannerEvent previous,
) => fresh.copyWith(
  reminderMinutesBefore: previous.reminderMinutesBefore,
  tagIds: previous.tagIds,
);

/// Merges the canonical copy returned by a remote write with the saved
/// local event. Google owns subject/times/recurrence/ids; everything the
/// user set locally (task flag, people, place, completion, timers) must
/// survive the round trip.
PlannerEvent preserveLocalFieldsOnWrite(
  PlannerEvent fresh,
  PlannerEvent local,
) {
  // Write responses omit the calendar-level color enrichment a full fetch
  // applies; keep the local color rather than flashing the feed default
  // until the next resync.
  final base = fresh.colorValue == null && local.colorValue != null
      ? fresh.copyWith(colorValue: local.colorValue)
      : fresh;
  return preserveLocalFeedMetadata(
    base.copyWith(
      isTask: local.isTask,
      done: local.done,
      completedAt: local.completedAt,
      clearCompletedAt: !local.done || local.completedAt == null,
      taskId: local.taskId,
      clearTaskId: local.taskId == null,
      placeId: local.placeId,
      clearPlaceId: local.placeId == null,
      assignees: local.assignees,
      sessions: local.sessions,
      actualStart: local.actualStart,
      clearActualStart: local.actualStart == null,
      actualEnd: local.actualEnd,
      clearActualEnd: local.actualEnd == null,
      timerStartedAt: local.timerStartedAt,
      clearTimerStartedAt: local.timerStartedAt == null,
      failed: local.failed,
    ),
    local,
  );
}

/// Builds the new identity for either calendar-move direction. Recording
/// history belongs to the event and must reach the destination before the
/// source is deleted, including legacy intervals and a running timer.
PlannerEvent eventDraftForCalendarMove({
  required PlannerEvent base,
  required String subject,
  required String? notes,
  required String? location,
  required DateTime start,
  required DateTime end,
  required bool allDay,
  required String rule,
  required String? taskId,
  required bool isTask,
  required bool done,
  required String? placeId,
  required List<TaskAssignee> assignees,
  required int? reminderMinutesBefore,
}) {
  final now = DateTime.now();
  return PlannerEvent(
    id: 'evt:${now.microsecondsSinceEpoch}',
    subject: subject,
    notes: notes,
    location: location,
    start: start,
    end: end,
    allDay: allDay,
    recurrenceRule: rule,
    taskId: taskId,
    isTask: isTask,
    done: done,
    completedAt: done ? (base.done ? base.completedAt ?? now : now) : null,
    placeId: placeId,
    assignees: List.of(assignees),
    reminderMinutesBefore: reminderMinutesBefore ?? base.reminderMinutesBefore,
    sessions: base.sessions,
    actualStart: base.actualStart,
    actualEnd: base.actualEnd,
    timerStartedAt: base.timerStartedAt,
  );
}
