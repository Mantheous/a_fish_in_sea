import 'package:equatable/equatable.dart';
import 'ical_recurrence.dart';

enum RepeatKind { none, daily, weekdays, weekly, biweekly, monthly, yearly }

enum RepeatEndKind { never, after, until }

class RepeatConfig extends Equatable {
  final RepeatKind kind;
  final Set<int> weekDays;
  final RepeatEndKind endKind;
  final int count;
  final DateTime? until;

  const RepeatConfig({
    this.kind = RepeatKind.none,
    this.weekDays = const {},
    this.endKind = RepeatEndKind.never,
    this.count = 0,
    this.until,
  });

  bool get isRepeating => kind != RepeatKind.none;

  String ruleFor(DateTime start) {
    final base = switch (kind) {
      RepeatKind.none => '',
      RepeatKind.daily => 'FREQ=DAILY',
      RepeatKind.weekdays => 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
      RepeatKind.weekly =>
        'FREQ=WEEKLY;BYDAY=${_dayCodes(weekDays.isEmpty ? {start.weekday} : weekDays)}',
      RepeatKind.biweekly =>
        'FREQ=WEEKLY;INTERVAL=2;BYDAY=${_dayCodes(weekDays.isEmpty ? {start.weekday} : weekDays)}',
      RepeatKind.monthly => 'FREQ=MONTHLY;BYMONTHDAY=${start.day}',
      RepeatKind.yearly =>
        'FREQ=YEARLY;BYMONTH=${start.month};BYMONTHDAY=${start.day}',
    };
    if (base.isEmpty) return '';
    return switch (endKind) {
      RepeatEndKind.never => base,
      RepeatEndKind.after => '$base;COUNT=${count < 1 ? 1 : count}',
      RepeatEndKind.until =>
        '$base;UNTIL=${_formatUntil(until!)}',
    };
  }

  static RepeatConfig? tryParse(String rule) {
    if (rule.isEmpty) return null;
    String? freq;
    int interval = 1;
    int? count;
    DateTime? until;
    final byDays = <int>{};
    int? byMonthDay;
    int? byMonth;
    for (final part in rule.split(';')) {
      final i = part.indexOf('=');
      if (i < 0) continue;
      final key = part.substring(0, i).toUpperCase();
      final value = part.substring(i + 1);
      switch (key) {
        case 'FREQ':
          freq = value.toUpperCase();
          break;
        case 'INTERVAL':
          interval = int.tryParse(value) ?? 1;
          break;
        case 'COUNT':
          count = int.tryParse(value);
          break;
        case 'UNTIL':
          until = _parseUntil(value);
          break;
        case 'BYDAY':
          for (final token in value.split(',')) {
            final day = _dayFromCode(token.trim());
            if (day == null) return null;
            byDays.add(day);
          }
          break;
        case 'BYMONTHDAY':
          byMonthDay = int.tryParse(value);
          break;
        case 'BYMONTH':
          byMonth = int.tryParse(value);
          break;
      }
    }
    final endKind = count != null
        ? RepeatEndKind.after
        : until != null
            ? RepeatEndKind.until
            : RepeatEndKind.never;
    final config = RepeatConfig(
      kind: RepeatKind.none,
      weekDays: byDays,
      endKind: endKind,
      count: count ?? 0,
      until: until,
    );
    switch (freq) {
      case 'DAILY':
        if (interval != 1) return null;
        return _copy(config, kind: RepeatKind.daily);
      case 'WEEKLY':
        if (interval == 2) return _copy(config, kind: RepeatKind.biweekly);
        if (interval != 1) return null;
        if (byDays.length == 5 && byDays.containsAll(const {1, 2, 3, 4, 5})) {
          return _copy(config, kind: RepeatKind.weekdays);
        }
        if (byDays.isNotEmpty) {
          return _copy(config, kind: RepeatKind.weekly);
        }
        return null;
      case 'MONTHLY':
        if (interval != 1 || byMonthDay == null) return null;
        return _copy(config, kind: RepeatKind.monthly);
      case 'YEARLY':
        if (interval != 1 || byMonthDay == null || byMonth == null) {
          return null;
        }
        return _copy(config, kind: RepeatKind.yearly);
      default:
        return null;
    }
  }

  static RepeatConfig _copy(
    RepeatConfig config, {
    required RepeatKind kind,
  }) =>
      RepeatConfig(
        kind: kind,
        weekDays: config.weekDays,
        endKind: config.endKind,
        count: config.count,
        until: config.until,
      );

  static String _formatUntil(DateTime until) {
    final utc = DateTime.utc(until.year, until.month, until.day, 23, 59);
    String pad2(int value) => value.toString().padLeft(2, '0');
    final date =
        '${utc.year.toString().padLeft(4, '0')}${pad2(utc.month)}${pad2(utc.day)}';
    final time = '${pad2(utc.hour)}${pad2(utc.minute)}00';
    return '${date}T${time}Z';
  }

  static DateTime? _parseUntil(String value) {
    final cleaned = value.trim().toUpperCase();
    final dateOnly = RegExp(r'^\d{8}$').firstMatch(cleaned);
    final full = RegExp(r'^(\d{8})T(\d{6})Z$').firstMatch(cleaned);
    if (full != null) {
      final datePart = full.group(1)!;
      final timePart = full.group(2)!;
      return DateTime.utc(
        int.parse(datePart.substring(0, 4)),
        int.parse(datePart.substring(4, 6)),
        int.parse(datePart.substring(6, 8)),
        int.parse(timePart.substring(0, 2)),
        int.parse(timePart.substring(2, 4)),
        int.parse(timePart.substring(4, 6)),
      ).toLocal();
    }
    if (dateOnly != null) {
      final datePart = cleaned;
      return DateTime.utc(
        int.parse(datePart.substring(0, 4)),
        int.parse(datePart.substring(4, 6)),
        int.parse(datePart.substring(6, 8)),
      ).toLocal();
    }
    return null;
  }

  static String _dayCodes(Set<int> days) =>
      days.map(_dayCode).join(',');

  static String _dayCode(int weekday) => switch (weekday) {
        DateTime.monday => 'MO',
        DateTime.tuesday => 'TU',
        DateTime.wednesday => 'WE',
        DateTime.thursday => 'TH',
        DateTime.friday => 'FR',
        DateTime.saturday => 'SA',
        DateTime.sunday => 'SU',
        _ => 'MO',
      };

  static int? _dayFromCode(String token) {
    if (token.length != 2) return null;
    return switch (token.toUpperCase()) {
      'MO' => DateTime.monday,
      'TU' => DateTime.tuesday,
      'WE' => DateTime.wednesday,
      'TH' => DateTime.thursday,
      'FR' => DateTime.friday,
      'SA' => DateTime.saturday,
      'SU' => DateTime.sunday,
      _ => null,
    };
  }

  RepeatConfig copyWith({
    RepeatKind? kind,
    Set<int>? weekDays,
    RepeatEndKind? endKind,
    int? count,
    DateTime? until,
  }) =>
      RepeatConfig(
        kind: kind ?? this.kind,
        weekDays: weekDays ?? this.weekDays,
        endKind: endKind ?? this.endKind,
        count: count ?? this.count,
        until: until ?? this.until,
      );

  @override
  List<Object?> get props => [kind, weekDays, endKind, count, until];
}

RepeatConfig? repeatConfigFromICal(ICalRecurrence recurrence, DateTime start) {
  if (recurrence.bySetPos != null ||
      (recurrence.byYearDay?.isNotEmpty ?? false) ||
      (recurrence.byWeek?.isNotEmpty ?? false) ||
      (recurrence.bySecond?.isNotEmpty ?? false) ||
      (recurrence.byMinute?.isNotEmpty ?? false) ||
      (recurrence.byHour?.isNotEmpty ?? false)) {
    return null;
  }
  final endKind = recurrence.count != null
      ? RepeatEndKind.after
      : recurrence.until != null
          ? RepeatEndKind.until
          : RepeatEndKind.never;
  RepeatKind kind;
  final days = <int>{};
  switch (recurrence.frequency) {
    case ICalFrequency.daily:
      if ((recurrence.byMonthDay?.isNotEmpty ?? false) ||
          (recurrence.byMonth?.isNotEmpty ?? false)) {
        return null;
      }
      kind = RepeatKind.daily;
      break;
    case ICalFrequency.weekly:
      if ((recurrence.byMonthDay?.isNotEmpty ?? false) ||
          (recurrence.byMonth?.isNotEmpty ?? false)) {
        return null;
      }
      if (recurrence.byWeekDay?.any((d) => d.hasWeekNumber) ?? false) {
        return null;
      }
      days.addAll(
        recurrence.byWeekDay?.map((d) => d.weekday) ?? <int>{},
      );
      kind = RepeatKind.weekly;
      break;
    case ICalFrequency.monthly:
      if (recurrence.byWeekDay != null ||
          (recurrence.byMonth?.isNotEmpty ?? false)) {
        return null;
      }
      final monthDays = recurrence.byMonthDay;
      if (monthDays != null && monthDays.length > 1) return null;
      kind = RepeatKind.monthly;
      break;
    case ICalFrequency.yearly:
      if (recurrence.byWeekDay != null) return null;
      final months = recurrence.byMonth;
      final monthDays = recurrence.byMonthDay;
      if (months != null && months.length > 1) return null;
      if (monthDays != null && monthDays.length > 1) return null;
      kind = RepeatKind.yearly;
      break;
    default:
      return null;
  }
  if (recurrence.interval > 2) return null;
  if (recurrence.interval == 2 && kind != RepeatKind.weekly) return null;
  final config = RepeatConfig(
    kind: recurrence.interval == 2 ? RepeatKind.biweekly : kind,
    weekDays: days,
    endKind: endKind,
    count: recurrence.count ?? 0,
    until: recurrence.until,
  );
  final rule = config.ruleFor(start);
  return rule.isEmpty ? null : config;
}
