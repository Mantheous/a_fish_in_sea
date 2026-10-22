import '../../finances/model/time_scale.dart';
import '../model/node.dart';

/// Calendar-date arithmetic for materializing recurring node templates.
///
/// Occurrences are anchored to the template's original date. Reconstructing
/// dates through the calendar constructor avoids 23/25-hour DST steps from
/// `Duration(days: ...)`, and the anchor day is retained when a month is
/// shorter than the requested day.
abstract final class NodeRecurrenceSchedule {
  static DateTime firstOnOrAfter(
    DateTime anchor,
    NodeRecurrence recurrence,
    DateTime from,
  ) {
    final first = _firstOccurrence(anchor, recurrence);
    if (!first.isBefore(_dateOnly(from))) return first;

    final interval = _calendarInterval(recurrence);
    if (interval != null) {
      final elapsed = _dayNumber(_dateOnly(from)) - _dayNumber(first);
      final periods = (elapsed / interval).ceil();
      var cursor = _addCalendarDays(first, periods * interval);
      if (cursor.isBefore(_dateOnly(from))) {
        cursor = _addCalendarDays(cursor, interval);
      }
      return cursor;
    }

    var cursor = first;
    var guard = 0;
    while (cursor.isBefore(_dateOnly(from)) && guard++ < 5000) {
      cursor = next(anchor, cursor, recurrence);
    }
    return cursor;
  }

  static DateTime next(
    DateTime anchor,
    DateTime current,
    NodeRecurrence recurrence,
  ) {
    switch (recurrence.frequency) {
      case TimeScale.daily:
        return _addCalendarDays(current, 1);
      case TimeScale.weekly:
        return _addCalendarDays(current, 7);
      case TimeScale.biweekly:
        return _addCalendarDays(current, 14);
      case TimeScale.custom:
        return _addCalendarDays(current, _positivePeriod(recurrence));
      case TimeScale.monthly:
        final month = DateTime(current.year, current.month + 1, 1);
        return _dateInMonth(
          month.year,
          month.month,
          recurrence.dayOfMonth ?? anchor.day,
          anchor.isUtc,
        );
      case TimeScale.quarterly:
        final month = DateTime(current.year, current.month + 3, 1);
        return _dateInMonth(month.year, month.month, anchor.day, anchor.isUtc);
      case TimeScale.yearly:
        return _dateInMonth(
          current.year + 1,
          anchor.month,
          anchor.day,
          anchor.isUtc,
        );
    }
  }

  static DateTime _firstOccurrence(DateTime anchor, NodeRecurrence recurrence) {
    final date = _dateOnly(anchor);
    switch (recurrence.frequency) {
      case TimeScale.monthly:
        return _dateInMonth(
          anchor.year,
          anchor.month,
          recurrence.dayOfMonth ?? anchor.day,
          anchor.isUtc,
        );
      case TimeScale.weekly:
      case TimeScale.biweekly:
        final target = recurrence.dayOfWeek;
        if (target == null ||
            target < DateTime.monday ||
            target > DateTime.sunday) {
          return date;
        }
        var difference = target - date.weekday;
        if (difference < 0) difference += DateTime.daysPerWeek;
        return _addCalendarDays(date, difference);
      case TimeScale.quarterly:
      case TimeScale.yearly:
      case TimeScale.daily:
      case TimeScale.custom:
        return date;
    }
  }

  static int? _calendarInterval(NodeRecurrence recurrence) =>
      switch (recurrence.frequency) {
        TimeScale.daily => 1,
        TimeScale.weekly => 7,
        TimeScale.biweekly => 14,
        TimeScale.custom => _positivePeriod(recurrence),
        _ => null,
      };

  static int _positivePeriod(NodeRecurrence recurrence) =>
      (recurrence.customPeriodDays ?? 30).clamp(1, 36500);

  static int _dayNumber(DateTime date) => DateTime.utc(
    date.year,
    date.month,
    date.day,
  ).difference(DateTime.utc(1970)).inDays;

  static DateTime _dateOnly(DateTime date) =>
      _makeDate(date.year, date.month, date.day, date.isUtc);

  static DateTime _addCalendarDays(DateTime date, int days) =>
      _makeDate(date.year, date.month, date.day + days, date.isUtc);

  static DateTime _dateInMonth(
    int year,
    int month,
    int requestedDay,
    bool utc,
  ) {
    final lastDay = DateTime(year, month + 1, 0).day;
    final day = requestedDay.clamp(1, lastDay);
    return _makeDate(year, month, day, utc);
  }

  static DateTime _makeDate(int year, int month, int day, bool utc) =>
      utc ? DateTime.utc(year, month, day) : DateTime(year, month, day);
}
