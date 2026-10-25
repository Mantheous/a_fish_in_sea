import '../../common/time/local_date.dart';
import '../../planner/bloc/calendar_cubit.dart';
import '../../planner/bloc/feed_cubit.dart';
import '../reporting_logic.dart';

// Weakly owned by the calendar: closing a session does not retain its data.
final _dayPlans = Expando<_DayPlanCache>();

/// Reuse recurrence expansion during scrubbing, tracking updates and Stats
/// builds. Immutable cubit state identity invalidates both edits and undo/redo.
List<PlannedSlice> daySlices(
  CalendarCubit calendar,
  FeedCubit feeds,
  DateTime day,
) {
  final cache = _dayPlans[calendar] ??= _DayPlanCache();
  return cache.get(calendar, feeds, day);
}

class _DayPlanCache {
  Object? _calendarState;
  Object? _feedState;
  final _days = <DateTime, List<PlannedSlice>>{};

  List<PlannedSlice> get(
    CalendarCubit calendar,
    FeedCubit feeds,
    DateTime day,
  ) {
    if (!identical(_calendarState, calendar.state) ||
        !identical(_feedState, feeds.state)) {
      _days.clear();
      _calendarState = calendar.state;
      _feedState = feeds.state;
    }
    final key = DateTime(day.year, day.month, day.day);
    final cached = _days[key];
    if (cached != null) return cached;
    final slices = List<PlannedSlice>.unmodifiable(
      _deriveDaySlices(calendar, feeds, key),
    );
    if (_days.length >= 31) _days.remove(_days.keys.first);
    _days[key] = slices;
    return slices;
  }
}

List<PlannedSlice> _deriveDaySlices(
  CalendarCubit calendar,
  FeedCubit feeds,
  DateTime day,
) {
  final dayStart = localDay(day);
  // Calendar-day end, not +24h: fall-back days are 25 hours long, so a
  // fixed duration would drop the last hour (or swallow an hour of the
  // next day on spring-forward).
  final dayEnd = shiftLocalDay(dayStart, 1);
  final onDay = calendar.eventsOnDay(day);
  final visible = feeds.visibleEvents(onDay);
  final slices = <PlannedSlice>[];
  for (final event in visible) {
    if (event.allDay) {
      if (event.start.isBefore(dayEnd) && event.endOfDay.isAfter(dayStart)) {
        slices.add(
          PlannedSlice(
            eventId: event.id,
            title: event.subject,
            placeId: event.placeId,
            start: dayStart,
            end: dayStart,
            allDay: true,
            classLabel: event.classLabel,
            taskId: event.taskId,
          ),
        );
      }
      continue;
    }
    final duration = event.end.isAfter(event.start)
        ? event.end.difference(event.start)
        : const Duration(hours: 1);
    for (final occ in calendar.occurrencesOf(event, dayStart, dayEnd)) {
      // Syncfusion includes occurrences from the end date. A day plan's
      // upper bound is exclusive, so tomorrow's event belongs to tomorrow.
      if (occ.isBefore(dayStart) || !occ.isBefore(dayEnd)) continue;
      slices.add(
        PlannedSlice(
          eventId: event.id,
          title: event.subject,
          placeId: event.placeId,
          start: occ,
          end: occ.add(duration),
          classLabel: event.classLabel,
          taskId: event.taskId,
        ),
      );
    }
  }
  slices.sort((a, b) => a.start.compareTo(b.start));
  return slices;
}
