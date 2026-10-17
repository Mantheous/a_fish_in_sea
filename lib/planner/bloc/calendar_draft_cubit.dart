import 'package:bloc/bloc.dart';

import '../../nodes/model/node.dart';
import '../model/assignment_estimate.dart';
import '../model/planner_event.dart';

const String calendarDraftEventId = '__draft__';

/// Fallback start when there is no learned habit: 9 AM.
const int defaultSeedStartMinute = 9 * 60;

/// Seed for the "add assignment to calendar" flow.
///
/// The span comes from the assignment's estimate — a rule's explicit
/// number, the learned average for its classified type, the node's own
/// time target, or a plain hour — and the start comes from the learned
/// habitual start time when there is one, so work keeps landing in the
/// same slot and the habit sticks. Both are snapped to the calendar's
/// snap setting; the end is the start plus the estimate, so the user
/// drags from a correct block instead of a fixed hour.
///
/// A node that already has a schedule block keeps it: the user has
/// already placed this one, and re-seeding from an average would move
/// it for no reason.
PlannerEvent draftSeedFromNode(
  Node node, {
  DateTime? now,
  AssignmentEstimate? estimate,
  int snapMinutes = 15,
}) {
  final ref = now ?? DateTime.now();
  final existing = node.schedule;
  if (existing != null && existing.hasCalendarBlock && !existing.allDay) {
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

  final minutes = (estimate?.minutes ?? defaultAssignmentMinutes)
      .clamp(5, 24 * 60)
      .toInt();
  final snap = snapMinutes <= 0 ? 1 : snapMinutes;
  final anchor = node.schedule?.due ?? node.schedule?.start ?? now ?? ref;

  var startMinute = estimate?.preferredStartMinute ?? defaultSeedStartMinute;
  // A habit that would run past midnight is pulled back onto the anchor
  // day, leaving room for the last snap slot.
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
/// block they just finished. Nodes without a planned block — or whose
/// shifted block would still land in the past — fall back to
/// [draftSeedFromNode] on the unplaced node, which sizes from the estimate
/// and guarantees a future slot.
PlannerEvent draftSeedForFollowUp(
  Node node, {
  DateTime? now,
  AssignmentEstimate? estimate,
  int snapMinutes = 15,
}) {
  final ref = now ?? DateTime.now();
  final existing = node.schedule;
  if (existing != null &&
      existing.hasCalendarBlock &&
      !existing.allDay &&
      existing.start != null &&
      existing.end != null) {
    final duration = existing.end!.difference(existing.start!);
    final start = existing.start!.add(const Duration(days: 1));
    if (!start.isBefore(ref)) {
      final safeDuration =
          duration.isNegative ? const Duration(hours: 1) : duration;
      return PlannerEvent(
        id: calendarDraftEventId,
        subject: node.title,
        notes: node.notes,
        start: start,
        end: start.add(safeDuration),
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
