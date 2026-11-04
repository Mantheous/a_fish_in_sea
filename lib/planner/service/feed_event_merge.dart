import '../model/planner_event.dart';
import '../model/feed.dart';

/// Only class assignments support locally chosen work times.
bool isLocallySchedulableAssignment(PlannerEvent event, Feed? feed) =>
    event.isTask &&
    (feed?.kind == FeedKind.canvas || feed?.kind == FeedKind.learningSuite);

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
  return preserveLocalTaskState(base, local);
}

/// Chosen assignment work times belong to this device; untouched times
/// follow the source. All other local task metadata survives either refresh.
PlannerEvent preserveLocalTaskState(
  PlannerEvent fresh,
  PlannerEvent local, {
  bool preserveWorkTime = false,
}) {
  return preserveLocalFeedMetadata(
    fresh.copyWith(
      start: preserveWorkTime ? local.start : fresh.start,
      end: preserveWorkTime ? local.end : fresh.end,
      allDay: preserveWorkTime ? local.allDay : fresh.allDay,
      workTimeScheduled: local.workTimeScheduled,
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
