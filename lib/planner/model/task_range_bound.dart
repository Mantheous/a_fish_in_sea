import 'package:equatable/equatable.dart';

/// Hard bounds for day-offset bounds. Parsing clamps into this window.
const int taskDateRangeMinOffset = -365;
const int taskDateRangeMaxOffset = 365;

int clampTaskDateOffset(int value) =>
    value.clamp(taskDateRangeMinOffset, taskDateRangeMaxOffset);

/// Bounds for "N weeks out" on weekday bounds: negative looks back
/// (-1 = last week). The picker only offers -2–3.
const int taskRangeWeeksOutMin = -52;
const int taskRangeWeeksOutMax = 52;

/// How one end of a rolling custom range pins itself to the calendar.
enum TaskRangeBoundKind {
  /// No limit on this side: a start includes overdue items, an end never
  /// cuts off the future.
  unbounded,

  /// N days from today (negative looks back).
  offset,

  /// A named weekday N weeks out. Weeks start Monday: on Saturday Oct 17
  /// 2026, Monday of next week (weeksOut 1) is Oct 19 — "the next Monday
  /// that's not this week". Monday of this week (weeksOut 0) is Oct 12,
  /// and Sunday of last week (weeksOut -1) is Oct 11 — the Sunday that
  /// opened the current calendar span for Sunday-start readers.
  weekday,
}

const _weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// Full weekday name for a [DateTime.weekday] number (1 = Monday).
String taskRangeWeekdayName(int weekday) =>
    _weekdayNames[(weekday - 1).clamp(0, 6)];

/// One end of a rolling custom date range. Unbounded ends never narrow;
/// offsets count days from today; weekday ends snap to a named weekday
/// in the current week plus [weeksOut].
class TaskRangeBound extends Equatable {
  final TaskRangeBoundKind kind;

  /// Days from today. Only read when [kind] is [TaskRangeBoundKind.offset].
  final int offsetDays;

  /// 1 = Monday … 7 = Sunday. Only read for
  /// [TaskRangeBoundKind.weekday].
  final int weekday;

  /// 0 = this week, 1 = next week, -1 = last week, and so on. Only read
  /// for weekday.
  final int weeksOut;

  const TaskRangeBound.unbounded()
      : kind = TaskRangeBoundKind.unbounded,
        offsetDays = 0,
        weekday = 1,
        weeksOut = 0;

  const TaskRangeBound.offset([this.offsetDays = 0])
      : kind = TaskRangeBoundKind.offset,
        weekday = 1,
        weeksOut = 0;

  const TaskRangeBound.weekday({this.weekday = 1, this.weeksOut = 0})
      : kind = TaskRangeBoundKind.weekday,
        offsetDays = 0;

  bool get isUnbounded => kind == TaskRangeBoundKind.unbounded;

  /// The calendar day this end resolves to for [now] (day precision),
  /// or null when unbounded. [firstDayOfWeek] is 1 = Monday … 7 = Sunday
  /// and sets which day opens the week for weekday bounds.
  DateTime? resolve(DateTime now, {int firstDayOfWeek = 1}) {
    final today = DateTime(now.year, now.month, now.day);
    switch (kind) {
      case TaskRangeBoundKind.unbounded:
        return null;
      case TaskRangeBoundKind.offset:
        return today.add(Duration(days: offsetDays));
      case TaskRangeBoundKind.weekday:
        final startOffset = (today.weekday - firstDayOfWeek + 7) % 7;
        final weekStart = today.subtract(Duration(days: startOffset));
        final position = (weekday - firstDayOfWeek + 7) % 7;
        return weekStart.add(Duration(days: position + weeksOut * 7));
    }
  }

  /// Relative phrase, e.g. "tomorrow" or "Monday of next week".
  String describe() => switch (kind) {
        TaskRangeBoundKind.unbounded => 'any time',
        TaskRangeBoundKind.offset => _offsetLabel(offsetDays),
        TaskRangeBoundKind.weekday =>
          '${taskRangeWeekdayName(weekday)} of ${_weeksOutLabel(weeksOut)}',
      };

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'offsetDays': offsetDays,
        'weekday': weekday,
        'weeksOut': weeksOut,
      };

  /// Null when [raw] is not a map. Unknown or missing kinds fall back to
  /// unbounded; wrong-typed numbers fall back to unbounded too (never
  /// silently narrow); out-of-range ints clamp.
  static TaskRangeBound? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map =
        raw is Map<String, dynamic> ? raw : Map<String, dynamic>.from(raw);
    TaskRangeBoundKind? kind;
    final rawKind = map['kind'];
    if (rawKind is String) {
      for (final k in TaskRangeBoundKind.values) {
        if (k.name == rawKind) kind = k;
      }
    }
    switch (kind) {
      case null:
      case TaskRangeBoundKind.unbounded:
        return const TaskRangeBound.unbounded();
      case TaskRangeBoundKind.offset:
        final v = map['offsetDays'];
        if (v is! int) return const TaskRangeBound.unbounded();
        return TaskRangeBound.offset(clampTaskDateOffset(v));
      case TaskRangeBoundKind.weekday:
        final w = map['weekday'];
        final n = map['weeksOut'];
        if (w is! int || n is! int) {
          return const TaskRangeBound.unbounded();
        }
        if (w < DateTime.monday || w > DateTime.sunday) {
          return const TaskRangeBound.unbounded();
        }
        return TaskRangeBound.weekday(
          weekday: w,
          weeksOut: n.clamp(taskRangeWeeksOutMin, taskRangeWeeksOutMax),
        );
    }
  }

  @override
  List<Object?> get props => [kind, offsetDays, weekday, weeksOut];
}

String _weeksOutLabel(int weeksOut) => switch (weeksOut) {
      0 => 'this week',
      1 => 'next week',
      -1 => 'last week',
      > 1 => 'in $weeksOut weeks',
      _ => '${-weeksOut} weeks ago',
    };

String _offsetLabel(int offset) => switch (offset) {
      0 => 'today',
      1 => 'tomorrow',
      -1 => 'yesterday',
      > 1 => 'in $offset days',
      _ => '${-offset} days ago',
    };
