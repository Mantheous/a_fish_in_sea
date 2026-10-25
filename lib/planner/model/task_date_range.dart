import 'package:equatable/equatable.dart';
import 'package:intl/intl.dart';

import 'task_range_bound.dart';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

final _shortFormat = DateFormat('MMM d');

/// A rolling custom date window: two independently pinned ends. Each end
/// is unbounded (start includes overdue, end never cuts off), a day
/// offset from today, or a named weekday N weeks out.
///
/// Examples: unbounded–tomorrow is "due tomorrow or earlier" (overdue +
/// today + tomorrow); today–+8 days is "today through eight days out";
/// unbounded–Monday-of-next-week is "overdue through next Monday".
class TaskDateRange extends Equatable {
  final TaskRangeBound start;
  final TaskRangeBound end;

  const TaskDateRange({
    this.start = const TaskRangeBound.unbounded(),
    this.end = const TaskRangeBound.unbounded(),
  });

  bool get isUnbounded => start.isUnbounded && end.isUnbounded;

  /// False when both ends resolve and start sits past end — nothing
  /// dated matches.
  bool isValidAt(DateTime now, {int firstDayOfWeek = 1}) {
    final s = start.resolve(now, firstDayOfWeek: firstDayOfWeek);
    final e = end.resolve(now, firstDayOfWeek: firstDayOfWeek);
    if (s == null || e == null) return true;
    return !s.isAfter(e);
  }

  DateTime? startDate(DateTime now, {int firstDayOfWeek = 1}) =>
      start.resolve(now, firstDayOfWeek: firstDayOfWeek);

  DateTime? endDate(DateTime now, {int firstDayOfWeek = 1}) =>
      end.resolve(now, firstDayOfWeek: firstDayOfWeek);

  bool matches(DateTime? due, DateTime now,
      {bool showUndated = false, int firstDayOfWeek = 1}) {
    if (due == null) return showUndated;
    final day = _day(due);
    final s = start.resolve(now, firstDayOfWeek: firstDayOfWeek);
    if (s != null && day.isBefore(s)) return false;
    final e = end.resolve(now, firstDayOfWeek: firstDayOfWeek);
    if (e != null && day.isAfter(e)) return false;
    return true;
  }

  TaskDateRange copyWith({TaskRangeBound? start, TaskRangeBound? end}) =>
      TaskDateRange(
        start: start ?? this.start,
        end: end ?? this.end,
      );

  Map<String, dynamic> toJson() => {
        'start': start.toJson(),
        'end': end.toJson(),
      };

  /// Null when [raw] is not a map. New payloads carry nested 'start' /
  /// 'end' bounds; payloads written before weekday anchors carry bare
  /// day-offset ints under 'startOffsetDays' / 'endOffsetDays' and parse
  /// onto equivalent offset bounds, so stored ranges keep working.
  static TaskDateRange? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map =
        raw is Map<String, dynamic> ? raw : Map<String, dynamic>.from(raw);
    if (map.containsKey('start') || map.containsKey('end')) {
      return TaskDateRange(
        start: TaskRangeBound.tryParse(map['start']) ??
            const TaskRangeBound.unbounded(),
        end: TaskRangeBound.tryParse(map['end']) ??
            const TaskRangeBound.unbounded(),
      );
    }
    TaskRangeBound legacyBound(Object? v) {
      if (v is! int) return const TaskRangeBound.unbounded();
      return TaskRangeBound.offset(clampTaskDateOffset(v));
    }

    return TaskDateRange(
      start: legacyBound(map['startOffsetDays']),
      end: legacyBound(map['endOffsetDays']),
    );
  }

  @override
  List<Object?> get props => [start, end];
}

/// Relative summary, e.g. "Due tomorrow or earlier",
/// "Due Monday of next week or earlier", or "Due today – in 8 days".
String describeTaskDateRange(TaskDateRange range) {
  final s = range.start;
  final e = range.end;
  if (s.isUnbounded && e.isUnbounded) return 'Any date';
  if (s.isUnbounded) return 'Due ${e.describe()} or earlier';
  if (e.isUnbounded) return 'Due ${s.describe()} or later';
  if (s == e) return 'Due ${s.describe()}';
  return 'Due ${s.describe()} – ${e.describe()}';
}

/// Resolved summary for the current day, e.g. "Oct 12 – Oct 20" or
/// "On or before Oct 13".
String resolvedTaskDateRange(TaskDateRange range, DateTime now,
    {int firstDayOfWeek = 1}) {
  final s = range.startDate(now, firstDayOfWeek: firstDayOfWeek);
  final e = range.endDate(now, firstDayOfWeek: firstDayOfWeek);
  if (s == null && e == null) return 'Any date';
  if (s == null) return 'On or before ${_shortFormat.format(e!)}';
  if (e == null) return '${_shortFormat.format(s)} or later';
  return '${_shortFormat.format(s)} – ${_shortFormat.format(e)}';
}
