/// Local wall-clock calendar helpers shared by every date rule and filter.
///
/// Dates the user picked (a due date, a calendar day, a report bucket) are
/// *local wall-clock* values: Oct 12 means Oct 12 on the device, not the
/// UTC instant that happens to contain it. Two rules follow from that:
///
///  1. Normalize parsed values to local before reading year/month/day —
///     a payload with a `Z` or offset (old data, another device, a server
///     round-trip) otherwise reads as the wrong local day ([localDay]).
///  2. Step dates through the calendar constructor, never
///     `Duration(days: n)`: a DST day is 23 or 25 hours long, so adding
///     "one day" of elapsed time can land on 00:00 of the wrong date
///     ([shiftLocalDay]).
///
/// Pure functions, no Flutter imports, so model code and tests can use
/// them freely.
library;

/// Local midnight of the calendar day containing [value].
DateTime localDay(DateTime value) {
  final local = value.isUtc ? value.toLocal() : value;
  return DateTime(local.year, local.month, local.day);
}

/// [day]'s date stepped by [days] calendar days, at local midnight.
///
/// Use this instead of `day.add(Duration(days: days))` for due-date
/// windows, week ends, and day stepping.
DateTime shiftLocalDay(DateTime day, int days) => DateTime(day.year, day.month, day.day + days);

/// [value] shifted by whole calendar days while keeping its wall-clock
/// time and zone kind (local stays local, UTC stays UTC).
///
/// Deadlines and follow-up blocks use this: 23:59 on Oct 30 shifted two
/// days is 23:59 on Nov 1 even though a DST change made the elapsed
/// interval 49 or 50 hours.
DateTime shiftByCalendarDays(DateTime value, int days) {
  if (value.isUtc) {
    return DateTime.utc(
      value.year,
      value.month,
      value.day + days,
      value.hour,
      value.minute,
      value.second,
      value.millisecond,
      value.microsecond,
    );
  }
  return DateTime(
    value.year,
    value.month,
    value.day + days,
    value.hour,
    value.minute,
    value.second,
    value.millisecond,
    value.microsecond,
  );
}

/// True when [a] and [b] fall on the same local calendar day.
bool isSameLocalDay(DateTime a, DateTime b) => localDay(a) == localDay(b);

/// Whole calendar days from [from] to [to] (negative when [to] is earlier).
///
/// Compares UTC day numbers so a 23-hour spring-forward day still counts
/// as one day instead of rounding down to zero.
int localDayDistance(DateTime from, DateTime to) {
  final a = localDay(from);
  final b = localDay(to);
  return DateTime.utc(
    b.year,
    b.month,
    b.day,
  ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
}
