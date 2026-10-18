import 'package:bloc/bloc.dart';

import '../../nodes/model/node.dart';
import '../model/assignment_estimate.dart';
import '../model/planner_event.dart';

const String calendarDraftEventId = '__draft__';

/// Fallback start for a fresh seed: noon.
///
/// Noon is always inside the calendar's visible hours (the day window
/// defaults to 6 AM–midnight and can be trimmed narrower), so the ghost
/// can't land on, or outside, a grid edge the way a late/early default
/// can. Predicting the slot the user actually wants is deliberately left
/// to a later feature — the learned habitual start in
/// `AssignmentTypeEffort.preferredStartMinute` is the intended hook once
/// that data is trustworthy; until then the safe spot is noon.
const int defaultSeedStartMinute = 12 * 60;

/// Minimum recorded sessions behind a learned estimate before it is
/// trusted to size a seed. One stray recording must not set the duration
/// of every future block of that type.
const int minEstimateSamplesForSeed = 3;

/// Longest existing block a seed will reuse. Imported assignments keep
/// their window ("open date → due date") in the same start/end fields;
/// those spans run for days (or collapse to zero length) and are dates,
/// not planned work.
const Duration maxSeedBlockSpan = Duration(hours: 24);

/// Whether [schedule] holds a timed work block that a seed can reuse:
/// positive length, shorter than a day, and not an all-day date.
///
/// Feed imports park their assignment window in the same fields, so
/// without this check a new-event seed echoes the window's start —
/// typically 12:00 AM with no visible length in the editor.
bool isSeedableBlock(ScheduleFacet? schedule) {
  if (schedule == null || !schedule.hasCalendarBlock || schedule.allDay) {
    return false;
  }
  final span = schedule.end!.difference(schedule.start!);
  return span > Duration.zero && span < maxSeedBlockSpan;
}

/// Duration for a fresh seed, in minutes: the estimate when it is
/// trustworthy, else a plain hour.
///
/// Trustworthy means the number came from the user — a repeating
/// assignment rule's explicit estimate or the node's own time target — or
/// from at least [minEstimateSamplesForSeed] recorded sessions. One or two
/// sessions make the learned median a guess, not a measurement, so those
/// fall back to [defaultAssignmentMinutes].
int seedDurationMinutes(AssignmentEstimate? estimate) {
  if (estimate == null) return defaultAssignmentMinutes;
  switch (estimate.source) {
    case AssignmentEstimateSource.rule:
    case AssignmentEstimateSource.effort:
      return estimate.minutes;
    case AssignmentEstimateSource.learned:
      final samples = estimate.effort?.samples ?? 0;
      return samples >= minEstimateSamplesForSeed
          ? estimate.minutes
          : defaultAssignmentMinutes;
    case AssignmentEstimateSource.fallback:
      return defaultAssignmentMinutes;
  }
}

/// Seed for the "add assignment to calendar" flow.
///
/// The span comes from the assignment's estimate when it is trustworthy
/// ([seedDurationMinutes]) and the start is noon on the anchor day
/// ([defaultSeedStartMinute]) — the user drags from a sane block instead
/// of a fixed, possibly off-grid hour. Both ends are snapped to the
/// calendar's snap setting.
///
/// A node that already has a *placed* block keeps it: the user has
/// already put work in that slot, and re-seeding would move it for no
/// reason. Only real timed blocks count ([isSeedableBlock]) — imported
/// assignment windows seed fresh at noon instead of echoing their
/// midnight start and zero-length span.
PlannerEvent draftSeedFromNode(
  Node node, {
  DateTime? now,
  AssignmentEstimate? estimate,
  int snapMinutes = 15,
}) {
  final ref = now ?? DateTime.now();
  final existing = node.schedule;
  if (existing != null && isSeedableBlock(existing)) {
    return PlannerEvent(
      id: calendarDraftEventId,
      subject: node.title,
      notes: node.notes,
      start: existing.start!,
      end: existing.end!,
      classLabel: node.classLabel,
      taskId: node.id,
    );
  }

  final minutes = seedDurationMinutes(estimate).clamp(5, 24 * 60).toInt();
  final snap = snapMinutes <= 0 ? 1 : snapMinutes;
  final anchor = node.schedule?.due ?? node.schedule?.start ?? now ?? ref;

  var startMinute = defaultSeedStartMinute;
  // A very long block that would run past midnight is pulled back onto
  // the anchor day, leaving room for the last snap slot.
  if (startMinute + minutes > 24 * 60) {
    startMinute = snapMinuteOfDay(24 * 60 - minutes - snap, snap);
  }
  startMinute = snapMinuteOfDay(startMinute, snap);
  var start = _atMinuteOfDay(anchor, startMinute);

  final isToday = start.year == ref.year &&
      start.month == ref.month &&
      start.day == ref.day;
  if (isToday && start.isBefore(ref)) {
    // Never seed an event in the past: keep the current slot so the block
    // is still visible in today's column. A block starting exactly now is
    // fine; one starting earlier is not.
    final nowMinute = ref.hour * 60 + ref.minute;
    startMinute = snapMinuteOfDay(nowMinute, snap) < nowMinute
        ? nowMinute
        : snapMinuteOfDay(nowMinute, snap);
    start = _atMinuteOfDay(anchor, startMinute);
  }

  // Round the end up to the next snap boundary so snapping can never
  // shorten the estimate.
  var endMinute = startMinute + minutes;
  final remainder = endMinute % snap;
  if (remainder != 0) endMinute += snap - remainder;
  endMinute = endMinute.clamp(startMinute + snap, 24 * 60);
  final end = _atMinuteOfDay(anchor, endMinute);

  return PlannerEvent(
    id: calendarDraftEventId,
    subject: node.title,
    notes: node.notes,
    start: start,
    end: end,
    classLabel: node.classLabel,
    taskId: node.id,
  );
}

/// Seed for the "schedule follow-up" flow.
///
/// Same event shape as [draftSeedFromNode] so the calendar page handles it
/// identically (ghost draft → pick a time → Add), but anchored on the next
/// block instead of the current one: a node that already has a planned
/// block keeps its duration and time-of-day, shifted one day forward, so
/// the user drags from a sensible next slot instead of re-placing the
/// block they just finished. Only real timed blocks are carried forward
/// ([isSeedableBlock]) — imported assignment windows are not planned work
/// and seed fresh at noon like any unplaced node. Nodes without a planned
/// block — or whose shifted block would still land in the past — fall back
/// to [draftSeedFromNode] on the unplaced node, which sizes from the
/// estimate and guarantees a future slot.
PlannerEvent draftSeedForFollowUp(
  Node node, {
  DateTime? now,
  AssignmentEstimate? estimate,
  int snapMinutes = 15,
}) {
  final ref = now ?? DateTime.now();
  final existing = node.schedule;
  if (existing != null && isSeedableBlock(existing)) {
    final duration = existing.end!.difference(existing.start!);
    final start = existing.start!.add(const Duration(days: 1));
    if (!start.isBefore(ref)) {
      return PlannerEvent(
        id: calendarDraftEventId,
        subject: node.title,
        notes: node.notes,
        start: start,
        end: start.add(duration),
        classLabel: node.classLabel,
        taskId: node.id,
      );
    }
    final unplaced = node.copyWith(
      schedule: existing.copyWith(clearStart: true, clearEnd: true),
    );
    return draftSeedFromNode(
      unplaced,
      now: ref,
      estimate: estimate,
      snapMinutes: snapMinutes,
    );
  }
  return draftSeedFromNode(
    node,
    now: ref,
    estimate: estimate,
    snapMinutes: snapMinutes,
  );
}

DateTime _atMinuteOfDay(DateTime day, int minute) =>
    DateTime(day.year, day.month, day.day)
        .add(Duration(minutes: minute.clamp(0, 24 * 60)));

class CalendarDraftCubit extends Cubit<PlannerEvent?> {
  CalendarDraftCubit() : super(null);

  void requestDraft(PlannerEvent seed) => emit(seed);

  PlannerEvent? takePending() {
    final pending = state;
    if (pending != null) emit(null);
    return pending;
  }

  void clear() => emit(null);
}
