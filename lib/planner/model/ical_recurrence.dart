enum ICalFrequency { secondly, minutely, hourly, daily, weekly, monthly, yearly }

class ICalByDay {
  final int weekday;
  final int? week;
  const ICalByDay(this.weekday, {this.week});
  bool get hasWeekNumber => week != null;
}

class ICalRecurrence {
  final ICalFrequency frequency;
  final DateTime? until;
  final int? count;
  final int interval;
  final List<ICalByDay>? byWeekDay;
  final List<int>? bySecond;
  final List<int>? byMinute;
  final List<int>? byHour;
  final List<int>? byYearDay;
  final List<int>? byWeek;
  final List<int>? byMonth;
  final List<int>? byMonthDay;
  final List<int>? bySetPos;

  const ICalRecurrence({
    required this.frequency,
    this.until,
    this.count,
    this.interval = 1,
    this.byWeekDay,
    this.bySecond,
    this.byMinute,
    this.byHour,
    this.byYearDay,
    this.byWeek,
    this.byMonth,
    this.byMonthDay,
    this.bySetPos,
  });
}
