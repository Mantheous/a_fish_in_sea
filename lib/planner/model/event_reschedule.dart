import 'planner_event.dart';

const Duration minEventDuration = Duration(minutes: 15);

bool isDraggableEvent(PlannerEvent event) =>
    !event.isFromFeed && event.recurrenceRule.isEmpty;

DateTime stripSeconds(DateTime value) => DateTime(
      value.year,
      value.month,
      value.day,
      value.hour,
      value.minute,
    );

DateTime snapToInterval(DateTime value, int snapMinutes) {
  final stripped = stripSeconds(value);
  if (snapMinutes <= 1) return stripped;
  final totalMinutes = stripped.hour * 60 + stripped.minute;
  final snapped =
      ((totalMinutes + snapMinutes ~/ 2) ~/ snapMinutes) * snapMinutes;
  if (snapped >= 24 * 60) {
    final day = DateTime(stripped.year, stripped.month, stripped.day);
    return day.add(const Duration(days: 1));
  }
  return DateTime(
    stripped.year,
    stripped.month,
    stripped.day,
    snapped ~/ 60,
    snapped % 60,
  );
}

PlannerEvent shiftEvent(
  PlannerEvent event,
  DateTime droppingTime, {
  int snapMinutes = 1,
}) {
  final duration = event.end.isAfter(event.start)
      ? event.end.difference(event.start)
      : const Duration(hours: 1);
  if (event.allDay) {
    final day = DateTime(
      droppingTime.year,
      droppingTime.month,
      droppingTime.day,
    );
    return event.copyWith(start: day, end: day.add(duration));
  }
  final start = snapToInterval(droppingTime, snapMinutes);
  return event.copyWith(start: start, end: start.add(duration));
}

PlannerEvent resizeEvent(
  PlannerEvent event,
  DateTime? newStart,
  DateTime? newEnd, {
  int snapMinutes = 1,
}) {
  var start = newStart == null
      ? event.start
      : snapToInterval(newStart, snapMinutes);
  var end =
      newEnd == null ? event.end : snapToInterval(newEnd, snapMinutes);
  if (!end.isAfter(start) || end.difference(start) < minEventDuration) {
    end = start.add(minEventDuration);
  }
  return event.copyWith(start: start, end: end);
}

bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Returns an updated draft that follows the calendar to the currently
/// visible dates, or `null` when no travel is needed.
///
/// The ghost keeps its wall-clock time and duration — only the day moves —
/// so the user can page with the header arrows and then drag the ghost
/// to its final slot. When the draft day is already on screen, the ghost
/// stays put instead of jumping.
PlannerEvent? travelGhostToVisible(
  PlannerEvent draft,
  List<DateTime> visibleDates,
  DateTime? displayDate, {
  int snapMinutes = 1,
}) {
  if (visibleDates.isEmpty) return null;
  if (visibleDates.any((d) => isSameDay(d, draft.start))) return null;
  DateTime anchor = displayDate ??
      visibleDates[visibleDates.length ~/ 2];
  if (!visibleDates.any((d) => isSameDay(d, anchor))) {
    anchor = visibleDates[visibleDates.length ~/ 2];
  }
  final anchorDay = DateTime(anchor.year, anchor.month, anchor.day);
  if (isSameDay(anchorDay, draft.start)) return null;
  final duration = draft.end.isAfter(draft.start)
      ? draft.end.difference(draft.start)
      : const Duration(hours: 1);
  if (draft.allDay) {
    return draft.copyWith(start: anchorDay, end: anchorDay.add(duration));
  }
  final start = snapToInterval(
    DateTime(
      anchorDay.year,
      anchorDay.month,
      anchorDay.day,
      draft.start.hour,
      draft.start.minute,
    ),
    snapMinutes,
  );
  return draft.copyWith(start: start, end: start.add(duration));
}
