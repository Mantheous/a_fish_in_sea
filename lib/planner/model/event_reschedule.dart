import '../../common/time/local_date.dart';
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
  // DateTime rolls 24:00 into the next day at local midnight, so snapping
  // past 23:59 keeps the calendar date right across DST (never +24h).
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
    final day = localDay(droppingTime);
    // All-day spans count calendar days, not elapsed hours: dragging across
    // a DST change must not shorten or lengthen the window.
    final days = localDayDistance(event.start, event.end);
    final span = days < 1 ? 1 : days;
    return event.copyWith(start: day, end: shiftLocalDay(day, span));
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

bool isSameDay(DateTime a, DateTime b) => isSameLocalDay(a, b);

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
  final anchorDay = localDay(anchor);
  if (isSameDay(anchorDay, draft.start)) return null;
  final duration = draft.end.isAfter(draft.start)
      ? draft.end.difference(draft.start)
      : const Duration(hours: 1);
  if (draft.allDay) {
    final days = localDayDistance(draft.start, draft.end);
    return draft.copyWith(
      start: anchorDay,
      end: shiftLocalDay(anchorDay, days < 1 ? 1 : days),
    );
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
