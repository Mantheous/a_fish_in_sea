/// Time and goal reporting over a range.
///
/// The Stats page used to answer only "what fraction of my planned
/// events did I show up for", which is a question about places. This
/// library answers the questions the user actually asks of their own
/// planning data:
///
/// - How much time did I spend, per class?
/// - How much does one *kind* of assignment take (using the classified
///   template keys, so "video quiz" is one bucket, not five strings)?
/// - How much of my time was not accounted for at all?
/// - Which goals did I finish this week — including the ones that are
///   not about time (checklists, money, Anki)?
///
/// Design rules:
///
/// 1. Every input is plain already-persisted data. Nothing new is stored,
///    so nothing here can lose user data.
/// 2. Time is attributed exactly once. A merge step unions planned spans
///    with recorded sessions per day, so a session that ran over its
///    appointment does not inflate the totals.
/// 3. "Not accounted for" is honest and bounded: waking hours on a day
///    that had *some* accounted time, minus the accounted part. A day off
///    contributes zero — the app does not lecture about rest.
///
/// Pure functions only: no Flutter, no cubits, fully unit-testable.
library;

import '../../nodes/model/node.dart';
import '../../planner/model/assignment_estimate.dart';
import '../../planner/model/assignment_rule.dart';
import '../../planner/model/assignment_template.dart';
import 'model/reported_entry.dart';
import 'reporting_logic.dart';

/// Waking hours used for the "not accounted for" number. Local time.
const int statsWakingStartMinute = 7 * 60;
const int statsWakingEndMinute = 24 * 60;

int get statsWakingMinutes =>
    statsWakingEndMinute - statsWakingStartMinute;

/// Named ranges offered in the UI. Weeks start Monday, matching the
/// calendar's week view.
enum StatsRangePreset { thisWeek, lastWeek, thisMonth, last30 }

extension StatsRangePresetLabels on StatsRangePreset {
  String get label => switch (this) {
        StatsRangePreset.thisWeek => 'This week',
        StatsRangePreset.lastWeek => 'Last week',
        StatsRangePreset.thisMonth => 'This month',
        StatsRangePreset.last30 => 'Last 30 days',
      };
}

class StatsRange {
  final DateTime start;
  final DateTime end;
  final StatsRangePreset preset;

  const StatsRange({
    required this.start,
    required this.end,
    required this.preset,
  });

  bool contains(DateTime when) =>
      !when.isBefore(start) && when.isBefore(end);

  int get days => end.difference(start).inDays;
}

/// Monday 00:00 of the week containing [when].
DateTime weekStartOf(DateTime when) {
  final day = DateTime(when.year, when.month, when.day);
  return day.subtract(Duration(days: day.weekday - 1));
}

StatsRange statsRangeFor(
  StatsRangePreset preset, {
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  switch (preset) {
    case StatsRangePreset.thisWeek:
      final start = weekStartOf(at);
      return StatsRange(
        start: start,
        end: start.add(const Duration(days: 7)),
        preset: preset,
      );
    case StatsRangePreset.lastWeek:
      final start = weekStartOf(at).subtract(const Duration(days: 7));
      return StatsRange(
        start: start,
        end: start.add(const Duration(days: 7)),
        preset: preset,
      );
    case StatsRangePreset.thisMonth:
      final start = DateTime(at.year, at.month);
      final end = DateTime(at.year, at.month + 1);
      return StatsRange(start: start, end: end, preset: preset);
    case StatsRangePreset.last30:
      final today = DateTime(at.year, at.month, at.day);
      return StatsRange(
        start: today.subtract(const Duration(days: 29)),
        end: today.add(const Duration(days: 1)),
        preset: preset,
      );
  }
}

// ── Assignment / class time ───────────────────────────────────────────

/// A summed time bucket: one class, or one classified assignment type.
class TimeGroup {
  final String key;
  final String label;
  final String? classLabel;

  /// Minutes actually recorded on work in this group.
  final int trackedMinutes;

  /// Minutes on the calendar for this group with no recorded session.
  final int plannedMinutes;

  /// Sum of the estimates the app would have used for these items.
  final int estimateMinutes;

  final int assignmentCount;

  const TimeGroup({
    required this.key,
    required this.label,
    this.classLabel,
    this.trackedMinutes = 0,
    this.plannedMinutes = 0,
    this.estimateMinutes = 0,
    this.assignmentCount = 0,
  });

  int get totalMinutes => trackedMinutes + plannedMinutes;

  /// Planned over actual for this group, or null when nothing comparable.
  double? get accuracy =>
      trackedMinutes <= 0 ? null : plannedMinutes / trackedMinutes;
}

/// One assignment inside the range, biggest time consumer first.
class AssignmentTimeRow {
  final String nodeId;
  final String title;
  final String? classLabel;
  final String? templateKey;
  final String? typeLabel;
  final int trackedMinutes;
  final int plannedMinutes;
  final int estimateMinutes;
  final bool done;
  final DateTime? when;

  const AssignmentTimeRow({
    required this.nodeId,
    required this.title,
    this.classLabel,
    this.templateKey,
    this.typeLabel,
    this.trackedMinutes = 0,
    this.plannedMinutes = 0,
    this.estimateMinutes = 0,
    this.done = false,
    this.when,
  });

  /// Estimated over recorded. 1.0 = the estimate was right, 0.5 = the work
  /// took twice as long as the estimate, 2.0 = half as long. Null when
  /// nothing was recorded.
  double? get accuracy =>
      trackedMinutes <= 0 ? null : estimateMinutes / trackedMinutes;}

/// Per-day breakdown feeding the range totals.
class DayAccounting {
  final DateTime day;

  /// Waking-window minutes on a day that had any accounted time, else 0.
  final int windowMinutes;

  /// Union of planned + recorded spans, clipped to the waking window.
  final int coveredMinutes;

  final int plannedMinutes;
  final int trackedMinutes;
  final int trackedNotPlannedMinutes;

  const DayAccounting({
    required this.day,
    required this.windowMinutes,
    required this.coveredMinutes,
    this.plannedMinutes = 0,
    this.trackedMinutes = 0,
    this.trackedNotPlannedMinutes = 0,
  });

  /// Waking hours on an active day with nothing accounted: idling,
  /// breaks, transit, and anything else the app never saw.
  int get unaccountedMinutes =>
      windowMinutes <= coveredMinutes ? 0 : windowMinutes - coveredMinutes;

  double get coveragePct =>
      windowMinutes <= 0 ? 0 : (coveredMinutes / windowMinutes).clamp(0.0, 1.0);
}

class AssignmentTimeReport {
  final StatsRange range;

  /// Recorded sessions inside the range.
  final int trackedMinutes;

  /// Calendar blocks inside the range that have no recorded session.
  final int plannedMinutes;

  /// Recorded work that was never on the calendar.
  final int trackedNotPlannedMinutes;

  /// Waking hours, on days with any accounted time, minus the accounted
  /// part. Never negative, and zero on days off.
  final int unaccountedMinutes;

  final List<TimeGroup> byClass;
  final List<TimeGroup> byType;
  final List<AssignmentTimeRow> rows;
  final List<DayAccounting> days;

  final int assignmentsCompleted;
  final int assignmentsScheduled;

  const AssignmentTimeReport({
    required this.range,
    this.trackedMinutes = 0,
    this.plannedMinutes = 0,
    this.trackedNotPlannedMinutes = 0,
    this.unaccountedMinutes = 0,
    this.byClass = const [],
    this.byType = const [],
    this.rows = const [],
    this.days = const [],
    this.assignmentsCompleted = 0,
    this.assignmentsScheduled = 0,
  });

  int get accountedMinutes => trackedMinutes + plannedMinutes;

  /// Estimated over recorded, across everything that has both. 1.0 = the
  /// estimates are calibrated, 0.5 = the work consistently takes twice as
  /// long as estimated, 2.0 = half as long. This is the number to watch
  /// when deciding whether to trust the schedule the app proposes.
  double? get estimateAccuracy {
    var estimated = 0;
    var tracked = 0;
    for (final row in rows) {
      if (row.trackedMinutes <= 0) continue;
      estimated += row.estimateMinutes;
      tracked += row.trackedMinutes;
    }
    if (estimated <= 0 || tracked <= 0) return null;
    return estimated / tracked;
  }

  bool get hasData =>
      trackedMinutes > 0 || plannedMinutes > 0 || assignmentsCompleted > 0;
}

// ── Non-time goals ─────────────────────────────────────────────────────

/// What kind of goal a node is, for the goals summary.
enum GoalKind { checklist, automated, money, time, anki }

GoalKind goalKindOf(Node node) {
  if (node.auto != null) return GoalKind.automated;
  if (node.money != null) return GoalKind.money;
  if (node.effort != null) return GoalKind.time;
  if (node.anki != null) return GoalKind.anki;
  return GoalKind.checklist;
}

String goalKindLabel(GoalKind kind) => switch (kind) {
      GoalKind.checklist => 'Checklist',
      GoalKind.automated => 'Automated',
      GoalKind.money => 'Money',
      GoalKind.time => 'Time',
      GoalKind.anki => 'Review',
    };

/// A goal finished inside the range.
class CompletedGoalRow {
  final Node node;
  final GoalKind kind;
  final DateTime? completedAt;

  const CompletedGoalRow({
    required this.node,
    required this.kind,
    this.completedAt,
  });
}

class GoalRangeReport {
  /// Goals (non-homework nodes) completed inside the range.
  final List<CompletedGoalRow> completed;

  final int failed;
  final int open;
  final int overdue;

  /// Leaf checklist items ticked vs. total leaves, inside the range.
  final int checklistDone;
  final int checklistTotal;

  /// Money goals: target and what actually landed in them.
  final double moneyTarget;
  final double moneyActual;
  final int moneyGoalCount;

  /// Time goals: minutes recorded against their combined target.
  final int effortTargetMinutes;
  final int effortLoggedMinutes;
  final int effortGoalCount;

  /// Review (Anki) goals: cards reviewed against target.
  final int ankiReviews;
  final int ankiTarget;
  final int ankiGoalCount;

  /// Automated goals present in the range. Their readings need the task,
  /// and transaction stores, so the range report only counts
  /// them instead of folding them into the checklist ratio.
  final int automatedGoalCount;

  const GoalRangeReport({
    this.completed = const [],
    this.failed = 0,
    this.open = 0,
    this.overdue = 0,
    this.checklistDone = 0,
    this.checklistTotal = 0,
    this.moneyTarget = 0,
    this.moneyActual = 0,
    this.moneyGoalCount = 0,
    this.effortTargetMinutes = 0,
    this.effortLoggedMinutes = 0,
    this.effortGoalCount = 0,
    this.ankiReviews = 0,
    this.ankiTarget = 0,
    this.ankiGoalCount = 0,
    this.automatedGoalCount = 0,
  });

  double get checklistPct =>
      checklistTotal <= 0 ? 0 : (checklistDone / checklistTotal).clamp(0.0, 1.0);

  double get effortPct => effortTargetMinutes <= 0
      ? 0
      : (effortLoggedMinutes / effortTargetMinutes).clamp(0.0, 1.0);

  /// Money goals that landed at or past their target, as a fraction.
  double? get moneyPct => moneyTarget <= 0 ? null : moneyActual / moneyTarget;

  bool get hasData =>
      completed.isNotEmpty ||
      checklistTotal > 0 ||
      effortGoalCount > 0 ||
      moneyGoalCount > 0 ||
      ankiGoalCount > 0 ||
      automatedGoalCount > 0;
}

// ── Aggregation ────────────────────────────────────────────────────────

/// One timestamped span with an owner, used to union a day.
class _Span {
  final DateTime start;
  final DateTime end;
  final String groupKey;
  final String label;
  final String? classLabel;
  final String? templateKey;
  final String nodeId;
  final String title;
  final bool tracked;
  final int estimateMinutes;

  const _Span({
    required this.start,
    required this.end,
    required this.groupKey,
    required this.label,
    required this.nodeId,
    required this.title,
    this.classLabel,
    this.templateKey,
    this.tracked = false,
    this.estimateMinutes = 0,
  });

  int get minutes => end.isAfter(start) ? end.difference(start).inMinutes : 0;
}

DateTime _startOfDay(DateTime day) => DateTime(day.year, day.month, day.day);

int _overlap(DateTime aStart, DateTime aEnd, DateTime bStart, DateTime bEnd) {
  final start = aStart.isAfter(bStart) ? aStart : bStart;
  final end = aEnd.isBefore(bEnd) ? aEnd : bEnd;
  return end.isAfter(start) ? end.difference(start).inMinutes : 0;
}

/// Clamp a span to the waking window of [day].
({DateTime start, DateTime end})? _clipToWaking(DateTime day, DateTime s, DateTime e) {
  final windowStart =
      _startOfDay(day).add(const Duration(minutes: statsWakingStartMinute));
  final windowEnd =
      _startOfDay(day).add(const Duration(minutes: statsWakingEndMinute));
  final start = s.isAfter(windowStart) ? s : windowStart;
  final end = e.isBefore(windowEnd) ? e : windowEnd;
  if (!end.isAfter(start)) return null;
  return (start: start, end: end);
}

/// Split a span at each midnight so overnight work lands on both days
/// instead of dropping the post-midnight half.
List<_Span> _splitByDay(_Span span) {
  final out = <_Span>[];
  var cursor = span.start;
  while (cursor.isBefore(span.end)) {
    final dayEnd = _startOfDay(cursor).add(const Duration(days: 1));
    final pieceEnd = span.end.isBefore(dayEnd) ? span.end : dayEnd;
    out.add(_Span(
      start: cursor,
      end: pieceEnd,
      groupKey: span.groupKey,
      label: span.label,
      classLabel: span.classLabel,
      title: span.title,
      templateKey: span.templateKey,
      nodeId: span.nodeId,
      tracked: span.tracked,
      estimateMinutes: span.estimateMinutes,
    ));
    cursor = pieceEnd;
  }
  return out;
}

/// Sum the union of [spans] (minutes), merging overlaps so nothing is
/// double-counted.
int _unionMinutes(List<_Span> spans) {
  if (spans.isEmpty) return 0;
  final sorted = [...spans]..sort((a, b) => a.start.compareTo(b.start));
  var total = 0;
  DateTime? cursor;
  for (final span in sorted) {
    if (cursor == null || span.start.isAfter(cursor)) {
      total += span.minutes;
      cursor = span.end;
    } else if (span.end.isAfter(cursor)) {
      total += span.end.difference(cursor).inMinutes;
      cursor = span.end;
    }
  }
  return total;
}

/// Overlap of [spans] with every span in [others], in minutes.
int _overlapWith(List<_Span> spans, List<_Span> others) {
  if (spans.isEmpty || others.isEmpty) return 0;
  final sortedOthers = [...others]..sort((a, b) => a.start.compareTo(b.start));
  var total = 0;
  for (final span in spans) {
    for (final other in sortedOthers) {
      if (!other.end.isAfter(span.start)) continue;
      if (!other.start.isBefore(span.end)) break;
      total += _overlap(span.start, span.end, other.start, other.end);
    }
  }
  return total;
}

  /// Appends [node]'s report as a span on its day.
  void _addNodeSpans(List<Node> nodes, List<_Span> out, StatsRange range) {
    final byId = {for (final node in nodes) node.id: node};
    for (final node in nodes) {
      final start = node.actualStart;
      final end = node.actualEnd;
      if (start == null || end == null || !end.isAfter(start)) continue;
      if (!range.contains(start)) continue;
      final minutes = end.difference(start).inMinutes;
      if (minutes <= 0) continue;
      // A class-node membership unifies manual and imported work under one
      // class key; provenance ids remain the fallback for unbound work.
      final classNode =
          node.classNodeId == null ? null : byId[node.classNodeId];
      final scope = node.classNodeId ?? node.feedId ?? node.classId;
      out.add(_Span(
        start: start,
        end: end,
        groupKey: scope ?? 'unassigned',
        label: classNode?.title ?? node.classLabel ?? 'No class',
        classLabel: classNode?.title ?? node.classLabel,
        title: node.title,
        templateKey: node.isHomework ? assignmentTemplateKey(node.title) : null,
        nodeId: node.id,
        tracked: true,
      ));
    }
  }

/// Builds the assignment/class time report for one range.
///
/// [plannedSlices] is every planned calendar slice in the range (the day
/// review's `daySlices` output, merged across days), [nodes] the full node
/// list (used for class/type attribution and estimates), and
/// [reportedEntries] the day-review reports in the range. Only confirmed
/// (non-auto) non-missed entries count as recorded time: an auto "missed"
/// from skipping everything is the absence of work, not work.
AssignmentTimeReport buildAssignmentTimeReport({
  required StatsRange range,
  required List<PlannedSlice> plannedSlices,
  required List<Node> nodes,
  List<AssignmentRule> rules = const [],
  List<AssignmentTypeEffort> efforts = const [],
  List<ReportedEntry> reportedEntries = const [],
}) {
  final nodeById = {for (final n in nodes) n.id: n};

  final plannedSpans = <_Span>[];
  for (final slice in plannedSlices) {
    if (slice.allDay || slice.durationMin <= 0) continue;
    if (!range.contains(slice.start)) continue;
    final linked = slice.taskId == null ? null : nodeById[slice.taskId];
    final isAssignment = linked != null && linked.isHomework;
    final classNode =
        linked?.classNodeId == null ? null : nodeById[linked!.classNodeId];
    final label = classNode?.title ??
        ((slice.classLabel?.trim().isNotEmpty ?? false)
            ? slice.classLabel!.trim()
            : (linked?.classLabel ?? 'No class'));
    // Same scope key the learned effort index uses, so a class total and
    // a per-type total describe the same thing.
    final scope = linked == null
        ? (slice.classLabel?.trim() ?? 'unassigned')
        : (linked.classNodeId ?? linked.feedId ?? linked.classId ?? label);
    plannedSpans.add(_Span(
      start: slice.start,
      end: slice.end,
      groupKey: scope,
      label: label,
      classLabel: classNode?.title ?? linked?.classLabel ?? slice.classLabel,
      title: linked?.title ?? slice.title,
      templateKey: isAssignment ? assignmentTemplateKey(linked.title) : null,
      nodeId: slice.taskId ?? slice.eventId,
      estimateMinutes: linked == null
          ? 0
          : resolveAssignmentEstimate(
              node: linked,
              rules: rules,
              efforts: efforts,
            ).minutes,
    ));
  }

  final trackedSpans = <_Span>[];
  _addNodeSpans(nodes, trackedSpans, range);
  // Manual reports for events that no node backs (a plain calendar event
  // the user filled in by hand) still count as time.
  final backedEventIds = <String>{
    for (final n in nodes) ...[
      if (n.calendarEventId != null) n.calendarEventId!,
      if (n.sourceEventId != null) n.sourceEventId!,
    ],
  };
  for (final entry in reportedEntries) {
    // Missed events are the absence of work, and unconfirmed auto entries
    // are guesses: neither counts as recorded time.
    if (entry.auto || entry.status == ReportStatus.missed) continue;
    final eventId = entry.eventId;
    if (eventId != null && backedEventIds.contains(eventId)) continue;
    if (!range.contains(entry.start)) continue;
    trackedSpans.add(_Span(
      start: entry.start,
      end: entry.end.isAfter(entry.start)
          ? entry.end
          : entry.start.add(const Duration(minutes: 1)),
      groupKey: 'unassigned',
      label: 'No class',
      title: entry.title,
      nodeId: 'entry:${entry.eventId ?? entry.start.microsecondsSinceEpoch}',
      tracked: true,
    ));
  }

  // Bucket by day, then union planned vs. tracked inside the waking window
  // so nothing is counted twice. Spans are split at midnight first, so an
  // overnight session contributes to both days.
  final days = <DateTime, List<_Span>>{};
  final dayKeys = <DateTime>{};
  for (final span in [...plannedSpans, ...trackedSpans]) {
    for (final piece in _splitByDay(span)) {
      final day = _startOfDay(piece.start);
      if (!range.contains(day)) continue;
      dayKeys.add(day);
      days.putIfAbsent(day, () => []).add(piece);
    }
  }

  final accounting = <DayAccounting>[];
  final byClass = <String, TimeGroup>{};
  final byType = <String, TimeGroup>{};
  final rows = <AssignmentTimeRow>[];

  int plannedTotal = 0;
  int trackedTotal = 0;
  int trackedNotPlannedTotal = 0;
  int unaccountedTotal = 0;

  for (final day in dayKeys.toList()..sort()) {
    final daySpans = days[day]!;
    final clippedPlanned = <_Span>[];
    final clippedTracked = <_Span>[];
    for (final span in daySpans) {
      final clipped = _clipToWaking(day, span.start, span.end);
      if (clipped == null) continue;
      final copy = _Span(
        start: clipped.start,
        end: clipped.end,
        groupKey: span.groupKey,
        label: span.label,
        classLabel: span.classLabel,
        title: span.title,
        templateKey: span.templateKey,
        nodeId: span.nodeId,
        tracked: span.tracked,
        estimateMinutes: span.estimateMinutes,
      );
      (span.tracked ? clippedTracked : clippedPlanned).add(copy);
    }

    final covered = _unionMinutes([...clippedPlanned, ...clippedTracked]);
    final trackedToday = clippedTracked.fold(0, (a, b) => a + b.minutes);
    // Planned time that a recorded session already covers is dropped, so
    // the class/type totals stay faithful to what the user actually did.
    // The per-day bar uses the same net number, so planned + tracked can
    // never stack past the day's covered total (the chart axis).
    final countedPerPlanned = <int>[];
    var plannedToday = 0;
    for (final span in clippedPlanned) {
      final counted = span.minutes - _overlapWith([span], clippedTracked);
      countedPerPlanned.add(counted);
      if (counted > 0) plannedToday += counted;
    }
    final dayAccount = DayAccounting(
      day: day,
      // A day whose spans all fall outside the waking window (night-only
      // work) has nothing accounted: no window, so no penalty.
      windowMinutes: (clippedPlanned.isEmpty && clippedTracked.isEmpty)
          ? 0
          : statsWakingMinutes,
      coveredMinutes: covered,
      plannedMinutes: plannedToday,
      trackedMinutes: trackedToday,
    );
    accounting.add(dayAccount);
    unaccountedTotal += dayAccount.unaccountedMinutes;

    for (var i = 0; i < clippedPlanned.length; i++) {
      final span = clippedPlanned[i];
      final counted = countedPerPlanned[i];
      if (counted <= 0) continue;
      plannedTotal += counted;
      _addTo(byClass, span.groupKey, span.label, span.classLabel, planned: counted);
      if (span.templateKey != null) {
        _addTo(
          byType,
          '${span.groupKey}|${span.templateKey}',
          _typeLabel(span.title, span.templateKey!),
          span.classLabel,
          planned: counted,
          assignmentCount: 1,
        );
      }
    }
    for (final span in clippedTracked) {
      trackedTotal += span.minutes;
      _addTo(
          byClass, span.groupKey, span.label, span.classLabel, tracked: span.minutes);
      if (span.templateKey != null) {
        _addTo(
          byType,
          '${span.groupKey}|${span.templateKey}',
          _typeLabel(span.title, span.templateKey!),
          span.classLabel,
          tracked: span.minutes,
          assignmentCount: 1,
        );
      }
      final overlapsPlanned = _overlapWith([span], clippedPlanned) > 0;
      if (!overlapsPlanned) trackedNotPlannedTotal += span.minutes;
    }
  }

  // Per-assignment rows: everything with recorded or planned time inside
  // the range.
  for (final node in nodes) {
    final nodeId = node.id;
    final tracked = trackedSpans
        .where((s) => s.nodeId == nodeId)
        .fold(0, (a, b) => a + b.minutes);
    final planned = plannedSpans
        .where((s) => s.nodeId == nodeId)
        .fold(0, (a, b) => a + b.minutes);
    if (tracked <= 0 && planned <= 0) continue;
    final start = node.actualStart ?? node.schedule?.start;
    if (start == null || !range.contains(start)) continue;
    rows.add(AssignmentTimeRow(
      nodeId: nodeId,
      title: node.title,
      classLabel: node.classLabel,
      templateKey: node.isHomework ? assignmentTemplateKey(node.title) : null,
      typeLabel:
          node.isHomework ? _typeLabel(node.title, assignmentTemplateKey(node.title)) : null,
      trackedMinutes: tracked,
      plannedMinutes: planned,
      estimateMinutes: resolveAssignmentEstimate(
        node: node,
        rules: rules,
        efforts: efforts,
      ).minutes,
      done: node.isDone,
      when: start,
    ));
  }

  final completed = nodes.where((n) {
    if (!n.isHomework || !n.isDone) return false;
    final done = n.completedAt;
    return done != null && range.contains(done);
  }).length;

  final scheduled = nodes.where((n) => n.hasCalendarBlock).length;

  rows.sort((a, b) {
    final byTime = (b.trackedMinutes + b.plannedMinutes)
        .compareTo(a.trackedMinutes + a.plannedMinutes);
    if (byTime != 0) return byTime;
    return a.title.compareTo(b.title);
  });

  return AssignmentTimeReport(
    range: range,
    trackedMinutes: trackedTotal,
    plannedMinutes: plannedTotal,
    trackedNotPlannedMinutes: trackedNotPlannedTotal,
    unaccountedMinutes: unaccountedTotal,
    byClass: byClass.values.toList()
      ..sort((a, b) => b.totalMinutes.compareTo(a.totalMinutes)),
    byType: byType.values.toList()
      ..sort((a, b) => b.totalMinutes.compareTo(a.totalMinutes)),
    rows: rows,
    days: accounting,
    assignmentsCompleted: completed,
    assignmentsScheduled: scheduled,
  );
}

void _addTo(
  Map<String, TimeGroup> map,
  String key,
  String label,
  String? classLabel, {
  int tracked = 0,
  int planned = 0,
  int estimate = 0,
  int assignmentCount = 0,
}) {
  final existing = map[key];
  map[key] = TimeGroup(
    key: key,
    label: label,
    classLabel: classLabel,
    trackedMinutes: tracked + (existing?.trackedMinutes ?? 0),
    plannedMinutes: planned + (existing?.plannedMinutes ?? 0),
    estimateMinutes: estimate + (existing?.estimateMinutes ?? 0),
    assignmentCount: assignmentCount + (existing?.assignmentCount ?? 0),
  );
}

String _typeLabel(String title, String templateKey) {
  // The classification key is the base name shared by every instance
  // ("Video Quiz 3.1" and "Video Quiz 3.4b" are both "video quiz"), so
  // it is the label — title-cased because the key is normalized.
  final key = templateKey.trim();
  if (key.isEmpty) return title.trim();
  return _titleCase(key);
}

String _titleCase(String value) => value
    .split(' ')
    .map((word) =>
        word.isEmpty ? word : '${word[0].toUpperCase()}${word.substring(1)}')
    .join(' ');

/// Builds the non-time-goal summary for one range.
///
/// "Goals" here means anything that is not imported homework: checklists,
/// money targets, time targets, and review counters. Completion is read
/// from `completedAt`, so a goal finished today shows up in "this week"
/// even if it was opened months ago.
GoalRangeReport buildGoalRangeReport({
  required StatsRange range,
  required List<Node> nodes,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final completed = <CompletedGoalRow>[];
  var failed = 0;
  var open = 0;
  var overdue = 0;
  var checklistDone = 0;
  var checklistTotal = 0;
  var moneyTarget = 0.0;
  var moneyActual = 0.0;
  var moneyGoalCount = 0;
  var effortTarget = 0;
  var effortLogged = 0;
  var effortGoalCount = 0;
  var ankiReviews = 0;
  var ankiTarget = 0;
  var ankiGoalCount = 0;
  var automatedGoalCount = 0;

  // A leaf is a node nothing else points at — "no children", not "no
  // parents". Building the parent set once keeps that O(n) instead of a
  // scan per node.
  final isParent = <String>{};
  for (final node in nodes) {
    isParent.addAll(node.parentIds);
  }

  for (final node in nodes) {
    if (node.isHomework || node.isTemplate || node.isUnbounded) continue;
    final kind = goalKindOf(node);
    final leaf = !isParent.contains(node.id);
    // Finished goals keep their targets and logged progress: accumulate
    // before the done-skip below, so marking a goal Done does not erase
    // it from the totals.
    if (kind == GoalKind.automated) {
      automatedGoalCount++;
    } else if (kind == GoalKind.money) {
      final money = node.money!;
      moneyTarget += money.effectiveTarget;
      moneyActual += money.actualAmount ?? 0;
      moneyGoalCount++;
    } else if (kind == GoalKind.time) {
      effortTarget += node.effort!.targetMinutes;
      effortLogged += node.reportedDuration?.inMinutes ?? 0;
      effortGoalCount++;
    } else if (kind == GoalKind.anki) {
      final anki = node.anki!;
      ankiTarget += anki.targetReviews;
      ankiReviews += anki.reviewsActual ?? 0;
      ankiGoalCount++;
    }
    if (node.isDone) {
      final doneAt = node.completedAt;
      if (doneAt != null && range.contains(doneAt)) {
        completed.add(CompletedGoalRow(
          node: node,
          kind: kind,
          completedAt: doneAt,
        ));
      }
      // Done leaves still count toward the checklist ratio, so 3-of-5
      // stays honest instead of silently losing the ticks.
      if (kind == GoalKind.checklist && leaf) {
        checklistTotal++;
        checklistDone++;
      }
      continue;
    }
    if (node.status == NodeStatus.failed) {
      failed++;
    } else if (node.isOpen) {
      open++;
      if (node.isOverdueAt(at)) overdue++;
    }

    // Leaf checklist items are counted, parents are not, so a 3-of-5
    // checklist reports the items rather than the container.
    if (kind == GoalKind.checklist) {
      if (leaf) {
        checklistTotal++;
        if (node.isDone) checklistDone++;
      }
    }
  }

  completed.sort((a, b) {
    final at = b.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bt = a.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return at.compareTo(bt);
  });

  return GoalRangeReport(
    completed: completed,
    failed: failed,
    open: open,
    overdue: overdue,
    checklistDone: checklistDone,
    checklistTotal: checklistTotal,
    moneyTarget: moneyTarget,
    moneyActual: moneyActual,
    moneyGoalCount: moneyGoalCount,
    effortTargetMinutes: effortTarget,
    effortLoggedMinutes: effortLogged,
    effortGoalCount: effortGoalCount,
    ankiReviews: ankiReviews,
    ankiTarget: ankiTarget,
    ankiGoalCount: ankiGoalCount,
    automatedGoalCount: automatedGoalCount,
  );
}
