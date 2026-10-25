import 'package:equatable/equatable.dart';

import '../../nodes/model/node.dart';
import 'task_date_range.dart';

/// Date window for a task filter. [all] matches everything (the filter
/// then only restricts by status/kind/class/planning); [undated] matches
/// only items without a due date; [custom] matches a rolling
/// [TaskDateRange] window (day offsets from today, either end optional).
enum TaskFilterDate {
  all,
  overdue,
  today,
  tomorrow,
  thisWeek,
  next7Days,
  undated,
  custom,
}

/// Which provenance a filter keeps. Tabs already split To-Do from
/// Homework; this lets a saved view narrow further (e.g. a "Homework
/// only" view that still applies on the To-Do tab hides personal tasks).
enum TaskFilterKind { both, personal, homework }

/// Restriction on calendar planning. [plannedOnly] keeps items with a
/// future, non-all-day calendar entry; [unplannedOnly] keeps items
/// without one. This is the schedule button's tint condition, fed by the
/// same source (`futureCalendarEntryCounts` keys), so a tinted clock
/// always reads as planned and an untinted one as unplanned.
enum TaskFilterPlanned { all, plannedOnly, unplannedOnly }

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Pure date-window check shared by view filters and the highlight rule.
///
/// [due] is the node's due date (null = undated). Undated nodes match a
/// specific window only when [showUndated] is true; the legacy Today /
/// Overdue views hid undated items, so custom filters default the same
/// way. Window math mirrors [NodeCubit.dueThisWeekAt] (today through
/// Sunday inclusive) so highlights and filters agree with each other.
bool taskFilterDateMatches(
  TaskFilterDate date,
  DateTime? due,
  DateTime now, {
  bool showUndated = false,
}) {
  switch (date) {
    case TaskFilterDate.all:
      return true;
    case TaskFilterDate.custom:
      // Custom windows carry their own bounds ([TaskDateRange]) and go
      // through [TaskFilter.matches]; bare calls treat them as unbounded.
      return true;
    case TaskFilterDate.undated:
      return due == null;
    case TaskFilterDate.overdue:
      if (due == null) return showUndated;
      return _day(due).isBefore(_day(now));
    case TaskFilterDate.today:
      if (due == null) return showUndated;
      return _day(due) == _day(now);
    case TaskFilterDate.tomorrow:
      if (due == null) return showUndated;
      return _day(due) == _day(now).add(const Duration(days: 1));
    case TaskFilterDate.thisWeek:
      if (due == null) return showUndated;
      final today = _day(now);
      if (_day(due).isBefore(today)) return false;
      // DateTime.weekday: Monday = 1 … Sunday = 7. Days until Sunday;
      // Sunday itself rolls forward to next Sunday.
      var daysToSunday = DateTime.sunday - now.weekday;
      if (daysToSunday <= 0) daysToSunday += 7;
      // +1 so a due date on Sunday itself is still inside the window.
      final endExclusive = today.add(Duration(days: daysToSunday + 1));
      return !due.isBefore(today) && due.isBefore(endExclusive);
    case TaskFilterDate.next7Days:
      if (due == null) return showUndated;
      final today = _day(now);
      final endExclusive = today.add(const Duration(days: 7));
      final day = _day(due);
      return !day.isBefore(today) && day.isBefore(endExclusive);
  }
}

/// One saved Tasks view: criteria for which rows stay visible while it is
/// the active filter. Views only ever hide — highlighting is the separate
/// [TaskHighlight] rule. Failed/skipped nodes never match (the Tasks page
/// has no UI for them); templates and unbounded goals are left to the base
/// lists, exactly like the legacy Today/Overdue id-sets.
class TaskFilter extends Equatable {
  /// Stable id. Defaults use 'all' / 'today' / 'overdue' (matching the
  /// legacy enum names so old prefs migrate by id); custom filters use
  /// the id minted by [newId].
  final String id;
  final String name;
  final TaskFilterDate date;

  /// True keeps done items; false hides them (legacy filtering hid
  /// completed items while a filter was on).
  final bool showCompleted;

  /// True keeps undated items inside a specific date window.
  final bool showUndated;

  final TaskFilterKind kind;

  /// Class keys (`classLabel ?? classId ?? ''`) a homework node must carry
  /// to match. Empty means all classes. Personal nodes ignore this list —
  /// pair it with [TaskFilterKind.homework] for a "Physics only" view, or
  /// leave [kind] on both to keep personal tasks alongside those classes.
  final List<String> classKeys;

  final TaskFilterPlanned planned;

  /// Rolling window used only when [date] is [TaskFilterDate.custom].
  /// Null means unbounded (matches any date, like [TaskFilterDate.all],
  /// but still honors [showUndated]).
  final TaskDateRange? customRange;

  const TaskFilter({
    required this.id,
    required this.name,
    this.date = TaskFilterDate.all,
    this.showCompleted = false,
    this.showUndated = false,
    this.kind = TaskFilterKind.both,
    this.classKeys = const [],
    this.planned = TaskFilterPlanned.all,
    this.customRange,
  });

  /// Id for a user-built filter.
  static String newId() =>
      'custom:${DateTime.now().microsecondsSinceEpoch}';

  /// True when this filter hides nothing the base lists already show: the
  /// [isFiltering] / badge signal and the "skip matching entirely"
  /// fast path both key off this.
  bool get isShowAll =>
      date == TaskFilterDate.all &&
      showCompleted &&
      kind == TaskFilterKind.both &&
      classKeys.isEmpty &&
      planned == TaskFilterPlanned.all;

  /// True when [node] passes every criterion.
  ///
  /// [plannedNodeIds] is the canonical planned set — the keys of
  /// `futureCalendarEntryCounts` (nodes with a future, non-all-day calendar
  /// entry; the schedule button tints exactly these). Callers with calendar
  /// data must pass it so the planned narrows match the tint. Null (standalone
  /// embeds, previews without a calendar) falls back to node-local data: only
  /// a future, non-all-day own block counts.
  bool matches(Node node, DateTime now, {Set<String>? plannedNodeIds}) {
    if (node.status == NodeStatus.open) {
      // Always kept (subject to the criteria below).
    } else if (node.status == NodeStatus.done && showCompleted) {
      // Kept.
    } else {
      return false;
    }
    switch (kind) {
      case TaskFilterKind.both:
        break;
      case TaskFilterKind.personal:
        if (node.isHomework) return false;
        break;
      case TaskFilterKind.homework:
        if (!node.isHomework) return false;
        break;
    }
    if (classKeys.isNotEmpty && node.isHomework) {
      final key = node.classLabel ?? node.classId ?? '';
      if (!classKeys.contains(key)) return false;
    }
    switch (planned) {
      case TaskFilterPlanned.all:
        break;
      case TaskFilterPlanned.plannedOnly:
        if (!_isPlanned(node, now, plannedNodeIds)) return false;
        break;
      case TaskFilterPlanned.unplannedOnly:
        if (_isPlanned(node, now, plannedNodeIds)) return false;
        break;
    }
    if (date == TaskFilterDate.all) return true;
    if (date == TaskFilterDate.undated) {
      return node.schedule?.due == null;
    }
    if (date == TaskFilterDate.custom) {
      return (customRange ?? const TaskDateRange()).matches(
        node.schedule?.due,
        now,
        showUndated: showUndated,
      );
    }
    return taskFilterDateMatches(
      date,
      node.schedule?.due,
      now,
      showUndated: showUndated,
    );
  }

  TaskFilter copyWith({
    String? id,
    String? name,
    TaskFilterDate? date,
    bool? showCompleted,
    bool? showUndated,
    TaskFilterKind? kind,
    List<String>? classKeys,
    TaskFilterPlanned? planned,
    TaskDateRange? customRange,
  }) =>
      TaskFilter(
        id: id ?? this.id,
        name: name ?? this.name,
        date: date ?? this.date,
        showCompleted: showCompleted ?? this.showCompleted,
        showUndated: showUndated ?? this.showUndated,
        kind: kind ?? this.kind,
        classKeys: classKeys ?? this.classKeys,
        planned: planned ?? this.planned,
        customRange: customRange ?? this.customRange,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'date': date.name,
        'showCompleted': showCompleted,
        'showUndated': showUndated,
        'kind': kind.name,
        'classKeys': classKeys,
        'planned': planned.name,
        'customRange': customRange?.toJson(),
      };

  /// Null when [raw] is not a usable filter (missing id, wrong shape) so
  /// callers can keep the valid entries and drop the garbage per-item.
  /// Unknown enum names fall back to the show-most default; wrong-typed
  /// scalars fall back to field defaults.
  static TaskFilter? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map =
        raw is Map<String, dynamic> ? raw : Map<String, dynamic>.from(raw);
    final id = map['id'];
    if (id is! String || id.isEmpty) return null;
    final rawName = map['name'];
    final name = rawName is String && rawName.trim().isNotEmpty
        ? rawName.trim()
        : 'Filter';
    T enumOr<T>(List<T> values, Object? v, T fallback, String Function(T) n) {
      if (v is! String) return fallback;
      for (final e in values) {
        if (n(e) == v) return e;
      }
      return fallback;
    }

    final rawKeys = map['classKeys'];
    final keys = <String>[];
    if (rawKeys is List) {
      for (final k in rawKeys) {
        if (k is String && k.isNotEmpty) keys.add(k);
        if (keys.length >= 32) break;
      }
    }
    return TaskFilter(
      id: id,
      name: name.length > 48 ? name.substring(0, 48) : name,
      date: enumOr(
          TaskFilterDate.values, map['date'], TaskFilterDate.all, (e) => e.name),
      showCompleted: map['showCompleted'] is bool
          ? map['showCompleted'] as bool
          : false,
      showUndated:
          map['showUndated'] is bool ? map['showUndated'] as bool : false,
      kind: enumOr(
          TaskFilterKind.values, map['kind'], TaskFilterKind.both, (e) => e.name),
      classKeys: keys,
      planned: enumOr(TaskFilterPlanned.values, map['planned'],
          TaskFilterPlanned.all, (e) => e.name),
      customRange: TaskDateRange.tryParse(map['customRange']),
    );
  }

  @override
  List<Object?> get props => [
        id,
        name,
        date,
        showCompleted,
        showUndated,
        kind,
        // Sorted for stable == across restores.
        [...classKeys]..sort(),
        planned,
        customRange,
      ];
}

/// Whether [node] counts as planned for [TaskFilterPlanned]: the schedule
/// button's tint condition. With [plannedNodeIds] (the canonical set from
/// `futureCalendarEntryCounts`) membership is the whole answer — the tile
/// tint and the filter share one source. Without calendar data, fall back
/// to the node's own block so standalone embeds still behave sensibly.
bool _isPlanned(Node node, DateTime now, Set<String>? plannedNodeIds) {
  if (plannedNodeIds != null) return plannedNodeIds.contains(node.id);
  final schedule = node.schedule;
  final start = schedule?.start;
  if (schedule == null ||
      start == null ||
      schedule.end == null ||
      schedule.allDay) {
    return false;
  }
  return start.isAfter(now);
}

/// The three legacy views as editable presets: All shows everything,
/// Today keeps open items due today, Overdue keeps open items past due.
/// Both date views hide completed and undated items, exactly like before.
List<TaskFilter> defaultTaskFilters() => const [
      TaskFilter(
        id: 'all',
        name: 'All',
        date: TaskFilterDate.all,
        showCompleted: true,
        showUndated: true,
      ),
      TaskFilter(
        id: 'today',
        name: 'Today',
        date: TaskFilterDate.today,
      ),
      TaskFilter(
        id: 'overdue',
        name: 'Overdue',
        date: TaskFilterDate.overdue,
      ),
    ];

/// Windows the highlight rule can tint. A subset of [TaskFilterDate] —
/// tinting everything ([all]) or only undated rows is never useful.
enum TaskHighlightDate { overdue, today, tomorrow, thisWeek, next7Days }

TaskFilterDate _highlightDateAsFilter(TaskHighlightDate date) =>
    taskFilterDateFromHighlight(date);

/// Public window mapping shared by the rules migration: a highlight
/// window becomes the equivalent view-filter window.
TaskFilterDate taskFilterDateFromHighlight(TaskHighlightDate date) =>
    switch (date) {
      TaskHighlightDate.overdue => TaskFilterDate.overdue,
      TaskHighlightDate.today => TaskFilterDate.today,
      TaskHighlightDate.tomorrow => TaskFilterDate.tomorrow,
      TaskHighlightDate.thisWeek => TaskFilterDate.thisWeek,
      TaskHighlightDate.next7Days => TaskFilterDate.next7Days,
    };

/// Independent tint (or hide) applied on top of the active view filter.
/// Only open nodes ever match, so done items never glow — same as the
/// legacy "highlight due this week" switch this replaces.
class TaskHighlight extends Equatable {
  final bool enabled;
  final TaskHighlightDate date;

  /// ARGB color for tinted rows. Null means the theme default (the legacy
  /// tertiary week tint). Rows due today always glow orange on top.
  final int? colorValue;

  /// The "Hide" color: matching items are hidden instead of tinted, so a
  /// highlight can double as a second hide rule (e.g. hide everything due
  /// tomorrow while the view shows the week).
  final bool hideMatching;

  const TaskHighlight({
    this.enabled = false,
    this.date = TaskHighlightDate.thisWeek,
    this.colorValue,
    this.hideMatching = false,
  });

  bool matches(Node node, DateTime now) {
    if (!enabled || !node.isOpen) return false;
    return taskFilterDateMatches(
      _highlightDateAsFilter(date),
      node.schedule?.due,
      now,
    );
  }

  TaskHighlight copyWith({
    bool? enabled,
    TaskHighlightDate? date,
    int? colorValue,
    bool clearColor = false,
    bool? hideMatching,
  }) =>
      TaskHighlight(
        enabled: enabled ?? this.enabled,
        date: date ?? this.date,
        colorValue: clearColor ? null : (colorValue ?? this.colorValue),
        hideMatching: hideMatching ?? this.hideMatching,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'date': date.name,
        'colorValue': colorValue,
        'hideMatching': hideMatching,
      };

  static TaskHighlight? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map =
        raw is Map<String, dynamic> ? raw : Map<String, dynamic>.from(raw);
    var date = TaskHighlightDate.thisWeek;
    final rawDate = map['date'];
    if (rawDate is String) {
      for (final d in TaskHighlightDate.values) {
        if (d.name == rawDate) date = d;
      }
    }
    int? color;
    final rawColor = map['colorValue'];
    if (rawColor is int && rawColor >= 0 && rawColor <= 0xFFFFFFFF) {
      color = rawColor;
    }
    return TaskHighlight(
      enabled: map['enabled'] is bool ? map['enabled'] as bool : false,
      date: date,
      colorValue: color,
      hideMatching:
          map['hideMatching'] is bool ? map['hideMatching'] as bool : false,
    );
  }

  @override
  List<Object?> get props => [enabled, date, colorValue, hideMatching];
}

/// Human labels shared by the views sheet and the filter builder.
String taskFilterDateLabel(TaskFilterDate date) => switch (date) {
      TaskFilterDate.all => 'Everything',
      TaskFilterDate.overdue => 'Overdue',
      TaskFilterDate.today => 'Due today',
      TaskFilterDate.tomorrow => 'Due tomorrow',
      TaskFilterDate.thisWeek => 'Due this week',
      TaskFilterDate.next7Days => 'Due in the next 7 days',
      TaskFilterDate.undated => 'Undated only',
      TaskFilterDate.custom => 'Custom range',
    };

String taskHighlightDateLabel(TaskHighlightDate date) => switch (date) {
      TaskHighlightDate.overdue => 'Overdue',
      TaskHighlightDate.today => 'Due today',
      TaskHighlightDate.tomorrow => 'Due tomorrow',
      TaskHighlightDate.thisWeek => 'Due this week',
      TaskHighlightDate.next7Days => 'Due in the next 7 days',
    };

String taskFilterKindLabel(TaskFilterKind kind) => switch (kind) {
      TaskFilterKind.both => 'Personal + homework',
      TaskFilterKind.personal => 'Personal only',
      TaskFilterKind.homework => 'Homework only',
    };

String taskFilterPlannedLabel(TaskFilterPlanned planned) => switch (planned) {
      TaskFilterPlanned.all => 'Planned + unplanned',
      TaskFilterPlanned.plannedOnly => 'Planned only',
      TaskFilterPlanned.unplannedOnly => 'Unplanned only',
    };

/// One-line summary for a saved view, e.g. "Due tomorrow · hides
/// completed · Homework only · Physics".
///
/// [className] resolves a class key for display, so feed-backed classes
/// show their name instead of a raw `feed:<id>` key.
String describeTaskFilter(
  TaskFilter filter, {
  String Function(String key)? className,
}) {
  final parts = <String>[];
  if (filter.date == TaskFilterDate.custom) {
    parts.add(
        describeTaskDateRange(filter.customRange ?? const TaskDateRange()));
  } else if (filter.date != TaskFilterDate.all) {
    parts.add(taskFilterDateLabel(filter.date));
  }
  parts.add(filter.showCompleted ? 'shows completed' : 'hides completed');
  if (filter.date != TaskFilterDate.all &&
      filter.date != TaskFilterDate.undated) {
    parts.add(filter.showUndated ? 'undated shown' : 'undated hidden');
  }
  if (filter.kind != TaskFilterKind.both) {
    parts.add(taskFilterKindLabel(filter.kind));
  }
  if (filter.classKeys.isNotEmpty) {
    final single = filter.classKeys.length == 1
        ? filter.classKeys.single
        : null;
    parts.add(
      single != null
          ? (className?.call(single) ?? single)
          : '${filter.classKeys.length} classes',
    );
  }
  if (filter.planned != TaskFilterPlanned.all) {
    parts.add(taskFilterPlannedLabel(filter.planned));
  }
  if (parts.isEmpty) return 'Both lists show everything.';
  return parts.join(' · ');
}
