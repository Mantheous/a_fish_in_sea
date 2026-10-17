import 'package:equatable/equatable.dart';
import 'package:intl/intl.dart';

/// Hard bounds for custom-range day offsets. Parsing clamps into this
/// window; the steppers never leave it.
const int taskDateRangeMinOffset = -365;
const int taskDateRangeMaxOffset = 365;

int clampTaskDateOffset(int value) =>
    value.clamp(taskDateRangeMinOffset, taskDateRangeMaxOffset);

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

final _shortFormat = DateFormat('MMM d');

/// A rolling custom date window: inclusive day offsets from today. Null
/// means unbounded on that side — a null start includes overdue items, a
/// null end never cuts off the future. Both null matches any date.
///
/// Examples: (null, 1) is "due tomorrow or earlier" (overdue + today +
/// tomorrow); (0, 8) is "today through eight days out".
class TaskDateRange extends Equatable {
  final int? startOffsetDays;
  final int? endOffsetDays;

  const TaskDateRange({this.startOffsetDays, this.endOffsetDays});

  bool get isUnbounded => startOffsetDays == null && endOffsetDays == null;

  /// False when the start sits past the end — nothing dated matches.
  bool get isValid {
    final s = startOffsetDays;
    final e = endOffsetDays;
    if (s == null || e == null) return true;
    return s <= e;
  }

  DateTime? startDate(DateTime now) {
    final s = startOffsetDays;
    if (s == null) return null;
    return _day(now).add(Duration(days: s));
  }

  DateTime? endDate(DateTime now) {
    final e = endOffsetDays;
    if (e == null) return null;
    return _day(now).add(Duration(days: e));
  }

  bool matches(DateTime? due, DateTime now, {bool showUndated = false}) {
    if (due == null) return showUndated;
    if (!isValid) return false;
    final day = _day(due);
    final today = _day(now);
    final s = startOffsetDays;
    if (s != null && day.isBefore(today.add(Duration(days: s)))) {
      return false;
    }
    final e = endOffsetDays;
    if (e != null && day.isAfter(today.add(Duration(days: e)))) {
      return false;
    }
    return true;
  }

  TaskDateRange copyWith({int? startOffsetDays, int? endOffsetDays}) =>
      TaskDateRange(
        startOffsetDays: startOffsetDays ?? this.startOffsetDays,
        endOffsetDays: endOffsetDays ?? this.endOffsetDays,
      );

  /// Same shape as the other models: explicit keys, nulls included, so a
  /// missing key and an explicit null parse the same way.
  Map<String, dynamic> toJson() => {
        'startOffsetDays': startOffsetDays,
        'endOffsetDays': endOffsetDays,
      };

  /// Null when [raw] is not a map. Wrong-typed offsets fall back to
  /// unbounded (never silently narrow); out-of-range ints clamp.
  static TaskDateRange? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map =
        raw is Map<String, dynamic> ? raw : Map<String, dynamic>.from(raw);
    int? offset(Object? v) {
      if (v == null) return null;
      if (v is! int) return null;
      return clampTaskDateOffset(v);
    }

    return TaskDateRange(
      startOffsetDays: offset(map['startOffsetDays']),
      endOffsetDays: offset(map['endOffsetDays']),
    );
  }

  @override
  List<Object?> get props => [startOffsetDays, endOffsetDays];
}

String _offsetLabel(int offset) => switch (offset) {
      0 => 'today',
      1 => 'tomorrow',
      -1 => 'yesterday',
      > 1 => 'in $offset days',
      _ => '${-offset} days ago',
    };

/// Relative summary, e.g. "Due tomorrow or earlier" or
/// "Due today – in 8 days".
String describeTaskDateRange(TaskDateRange range) {
  final s = range.startOffsetDays;
  final e = range.endOffsetDays;
  if (s == null && e == null) return 'Any date';
  if (s == null) {
    return e == 0 ? 'Due today or earlier' : 'Due ${_offsetLabel(e!)} or earlier';
  }
  if (e == null) {
    return s == 0 ? 'Due today or later' : 'Due ${_offsetLabel(s)} or later';
  }
  if (s == e) return 'Due ${_offsetLabel(s)}';
  return 'Due ${_offsetLabel(s)} – ${_offsetLabel(e)}';
}

/// Resolved summary for the current day, e.g. "Oct 12 – Oct 20" or
/// "On or before Oct 13".
String resolvedTaskDateRange(TaskDateRange range, DateTime now) {
  final s = range.startDate(now);
  final e = range.endDate(now);
  if (s == null && e == null) return 'Any date';
  if (s == null) return 'On or before ${_shortFormat.format(e!)}';
  if (e == null) return '${_shortFormat.format(s)} or later';
  return '${_shortFormat.format(s)} – ${_shortFormat.format(e)}';
}
