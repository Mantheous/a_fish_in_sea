import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';

import '../../common/time/local_date.dart';
import '../model/node.dart';
import 'auto_goal_format.dart';
import 'auto_goal_time.dart';

/// One rolling window for an automated goal: `[start, end)` in local time.
///
/// Windows are recomputed from the clock (and the goal's creation date for
/// custom/biweekly cadences) instead of being stored per period, so past
/// weeks can be re-evaluated from the same data without a snapshot table.
class AutoGoalWindow {
  final DateTime start;
  final DateTime end;

  const AutoGoalWindow({required this.start, required this.end});

  bool contains(DateTime at) => !at.isBefore(start) && at.isBefore(end);

  /// Calendar days in the window. A DST week is 167/169 hours but still 7
  /// days for daily-rate goals.
  int get days => localDayDistance(start, end);

  /// Minutes of `[from, to)` inside this window, clipped at both ends.
  /// Returns 0 for inverted or empty spans.
  double overlapMinutes(DateTime? from, DateTime? to) {
    if (from == null || to == null || !to.isAfter(from)) return 0;
    final s = from.isBefore(start) ? start : from;
    final e = to.isAfter(end) ? end : to;
    if (!e.isAfter(s)) return 0;
    return e.difference(s).inMinutes.toDouble();
  }
}

/// Start of the local day containing [at].
DateTime autoDay(DateTime at) => localDay(at);

/// The window containing [at] for [facet]. [anchor] is the goal's creation
/// day, used by biweekly and custom periods so they do not jump when the
/// calendar week changes.
AutoGoalWindow autoGoalWindow(
  AutoFacet facet,
  DateTime at, {
  DateTime? anchor,
}) {
  final day = autoDay(at);
  switch (facet.period) {
    case TimeScale.daily:
      return AutoGoalWindow(start: day, end: shiftLocalDay(day, 1));
    case TimeScale.weekly:
      final start = shiftLocalDay(day, -(day.weekday - 1));
      return AutoGoalWindow(
        start: start,
        end: shiftLocalDay(start, 7),
      );
    case TimeScale.biweekly:
      return _anchoredWindow(day, anchor ?? day, 14);
    case TimeScale.monthly:
      return AutoGoalWindow(
        start: DateTime(day.year, day.month),
        end: DateTime(day.year, day.month + 1),
      );
    case TimeScale.quarterly:
      final month = ((day.month - 1) ~/ 3) * 3 + 1;
      return AutoGoalWindow(
        start: DateTime(day.year, month),
        end: DateTime(day.year, month + 3),
      );
    case TimeScale.yearly:
      return AutoGoalWindow(
        start: DateTime(day.year),
        end: DateTime(day.year + 1),
      );
    case TimeScale.custom:
      final days = (facet.customPeriodDays ?? 30).clamp(1, 36500);
      return _anchoredWindow(day, anchor ?? day, days);
  }
}

AutoGoalWindow _anchoredWindow(DateTime day, DateTime anchor, int days) {
  final anchorDay = autoDay(anchor);
  final diff = localDayDistance(anchorDay, day);
  final index = (diff / days).floor();
  final start = shiftLocalDay(anchorDay, index * days);
  return AutoGoalWindow(
    start: start,
    end: shiftLocalDay(start, days),
  );
}

/// The measured value of one automated goal for its current window, plus
/// the formatting the UI and tests share.
class AutoGoalReading {
  final AutoFacet facet;

  /// Raw measured value in the facet's metric units (minutes, dollars,
  /// count, days, or percent for [AutoMetric.percentDone]).
  final double actual;
  final double target;

  /// Clamped 0–1 contribution to a parent's progress.
  final double progress;

  /// Whether the target direction is met.
  final bool satisfied;

  /// Contributing rows: tasks or transactions.
  final int matched;

  /// [AutoMetric.allDone] only: completed and total leaf work items.
  final int doneCount;
  final int totalCount;

  final DateTime windowStart;
  final DateTime windowEnd;

  const AutoGoalReading({
    required this.facet,
    required this.actual,
    required this.target,
    required this.progress,
    required this.satisfied,
    required this.matched,
    required this.windowStart,
    required this.windowEnd,
    this.doneCount = 0,
    this.totalCount = 0,
  });

  String get actualLabel => formatAutoValue(facet.metric, actual);
  String get targetLabel => formatAutoValue(facet.metric, target);

  /// "6h 20m / 7h", "$14.20 / $20.00", or "3 of 5 done".
  String get summary => facet.metric == AutoMetric.allDone
      ? '$doneCount of $totalCount done'
      : '$actualLabel / $targetLabel';

  /// "· 4 tasks" (empty when nothing matched).
  String get matchedLabel {
    if (matched <= 0) return '';
    final noun = switch (facet.source) {
      AutoSource.tasks => matched == 1 ? 'task' : 'tasks',
      AutoSource.money => matched == 1 ? 'transaction' : 'transactions',
    };
    return '$matched $noun';
  }

  /// "this week", "today", "this month", or "every 14 days".
  String get windowLabel => autoPeriodLabel(facet);
}

/// Evaluates [goal]'s automated facet at [now]. Pure: every input is an
/// already-persisted record, so the same call works for the live period
/// and for a past window (pass [at] for history).
AutoGoalReading evaluateAutoGoal(
  Node goal, {
  required DateTime now,
  required List<Node> nodes,
  List<Transaction> transactions = const [],
  DateTime? at,
  AutoFacet? facetOverride,
}) {
  final facet = facetOverride ?? goal.auto;
  final when = at ?? now;
  if (facet == null) {
    return AutoGoalReading(
      facet: const AutoFacet(),
      actual: 0,
      target: 0,
      progress: 0,
      satisfied: false,
      matched: 0,
      windowStart: when,
      windowEnd: when,
    );
  }
  final window = autoGoalWindow(facet, when, anchor: goal.createdAt);

  var actual = 0.0;
  var matched = 0;
  var doneCount = 0;
  var totalCount = 0;

  switch (facet.source) {
    case AutoSource.tasks:
      final pool = _taskPool(goal, facet, nodes);
      switch (facet.metric) {
        case AutoMetric.allDone:
          final work = _leafWork(pool, nodes);
          totalCount = work.length;
          doneCount = work.where((n) => n.isDone).length;
          matched = totalCount;
          actual = totalCount == 0
              ? 0
              : doneCount / totalCount * 100.0;
        case AutoMetric.minutes:
        case AutoMetric.averageMinutes:
          final days = <DateTime>{};
          for (final node in pool) {
            final minutes = _taskMinutesInWindow(node, window, when);
            if (minutes <= 0) continue;
            actual += minutes;
            matched++;
            if (facet.metric == AutoMetric.averageMinutes) {
              days.addAll(taskDaysInWindow(node, window.start, window.end));
            }
          }
          if (facet.metric == AutoMetric.averageMinutes && days.isNotEmpty) {
            actual /= days.length;
          }
        case AutoMetric.count:
          for (final node in pool) {
            if (!_completedIn(node, window)) continue;
            actual++;
            matched++;
          }
        case AutoMetric.days:
          final days = <DateTime>{};
          for (final node in pool) {
            if (!_completedIn(node, window)) continue;
            days.add(autoDay(node.completedAt!));
          }
          actual = days.length.toDouble();
          matched = days.length;
        case AutoMetric.percentDone:
          final due = _tasksDueInCheckWindow(pool, facet, window, when);
          matched = due.length;
          final done = due.where((n) => n.isDone).length;
          actual = due.isEmpty ? 100.0 : done / due.length * 100.0;
        case AutoMetric.amount:
          // Not offered for tasks; keep the evaluator total rather than
          // silently reading money.
          actual = 0;
      }
    case AutoSource.money:
      final ids = facet.scope == AutoScope.subtree
          ? (_subtreeIds(goal.id, nodes)..add(goal.id))
          : null;
      final matching = [
        for (final txn in transactions)
          if (txn.amount < 0 &&
              window.contains(txn.date) &&
              (ids == null || ids.contains(txn.assignedNodeId)) &&
              _moneyMatches(facet, txn))
            txn,
      ];
      matched = matching.length;
      switch (facet.metric) {
        case AutoMetric.amount:
          actual = matching.fold<double>(0, (sum, t) => sum - t.amount);
        case AutoMetric.count:
          actual = matching.length.toDouble();
        case AutoMetric.minutes:
        case AutoMetric.averageMinutes:
        case AutoMetric.days:
        case AutoMetric.percentDone:
        case AutoMetric.allDone:
          actual = 0;
      }
  }

  final allDone = facet.metric == AutoMetric.allDone;
  final target = allDone ? 100.0 : facet.target;
  final progress = _progress(facet, actual, target);
  final satisfied = allDone
      ? totalCount > 0 && doneCount == totalCount
      : target > 0 &&
            (facet.comparison == AutoComparison.atMost
                ? actual <= target
                : actual >= target);

  return AutoGoalReading(
    facet: facet,
    actual: actual,
    target: target,
    progress: progress,
    satisfied: satisfied,
    matched: matched,
    windowStart: window.start,
    windowEnd: window.end,
    doneCount: doneCount,
    totalCount: totalCount,
  );
}

/// All metric readings for one goal, in display order.
///
/// The first reading is the primary one shown on the row/progress bar.
/// [satisfied] is true only when every metric passes: metrics are all
/// statistics on the same goal and none is inherently "just a guardrail".
class GoalMetricsReading {
  final List<AutoGoalReading> readings;

  const GoalMetricsReading(this.readings);

  AutoGoalReading? get primary => readings.isEmpty ? null : readings.first;

  bool get hasMetrics => readings.isNotEmpty;

  bool get satisfied =>
      readings.isNotEmpty && readings.every((reading) => reading.satisfied);

  double get progress =>
      (primary?.progress ?? 0).clamp(0.0, 1.0);

  /// Primary summary, with a "+N" suffix when more metrics exist.
  String get summary {
    final first = primary;
    if (first == null) return 'no metrics';
    if (readings.length == 1) return first.summary;
    return '${first.summary} · +${readings.length - 1}';
  }
}

/// Readings for every metric on every goal in [nodes], keyed by node id.
Map<String, GoalMetricsReading> metricReadingsForNodes(
  List<Node> nodes, {
  required DateTime now,
  List<Transaction> transactions = const [],
}) {
  final out = <String, GoalMetricsReading>{};
  for (final node in nodes) {
    if (!node.hasMetrics) continue;
    out[node.id] = GoalMetricsReading([
      for (final metric in node.metrics)
        evaluateAutoGoal(
          node,
          now: now,
          nodes: nodes,
          transactions: transactions,
          facetOverride: metric,
        ),
    ]);
  }
  return out;
}

double _progress(AutoFacet facet, double actual, double target) {
  if (facet.metric == AutoMetric.allDone ||
      facet.metric == AutoMetric.percentDone) {
    return (actual / 100).clamp(0.0, 1.0);
  }
  if (target <= 0) return 0;
  if (facet.comparison == AutoComparison.atMost) {
    if (actual <= 0) return 1.0;
    return (target / actual).clamp(0.0, 1.0);
  }
  return (actual / target).clamp(0.0, 1.0);
}

List<Node> _taskPool(Node goal, AutoFacet facet, List<Node> nodes) {
  final ids = facet.scope == AutoScope.subtree
      ? (_subtreeIds(goal.id, nodes)..add(goal.id))
      : null;
  final keys = {for (final key in facet.classKeys) key.trim().toLowerCase()}
    ..removeWhere((key) => key.isEmpty);
  return [
    for (final node in nodes)
      if (node.id != goal.id &&
          !node.isTemplate &&
          !node.isUnbounded &&
          _inScope(goal, node, ids) &&
          (!facet.homeworkOnly || node.isHomework) &&
          _classMatches(node, keys))
        node,
  ];
}

/// True when [node] is inside a goal's scope. A class node's scope also
/// includes imported work from its bound feeds even before that work was
/// parented, so class metrics work on existing history without a
/// destructive migration.
bool _inScope(Node goal, Node node, Set<String>? subtreeIds) {
  if (subtreeIds == null) return true;
  if (subtreeIds.contains(node.id)) return true;
  if (goal.isClassNode) {
    if (node.classNodeId == goal.id) return true;
    return goal.classFacet!.matchesNodeSource(
      classSourceOfNode(
        feedId: node.feedId,
        classId: node.classId,
        classLabel: node.classLabel,
      ),
    );
  }
  return false;
}

/// Leaf work items: the things allDone can count. Class nodes and metric
/// goals are containers/measurements, not work; a class with only metric
/// goals should use a metric for completion instead of allDone.
List<Node> _leafWork(List<Node> pool, List<Node> nodes) {
  final parented = <String>{
    for (final node in nodes) ...node.parentIds,
  };
  return [
    for (final node in pool)
      if (!parented.contains(node.id) && !node.isClassNode && !node.hasMetrics)
        node,
  ];
}

bool _classMatches(Node node, Set<String> keys) {
  if (keys.isEmpty) return true;
  final key = autoClassKey(node);
  return key != null && keys.contains(key);
}

/// Normalized class key shared with the Tasks filters: label first, id
/// second. Lower-cased so "Physics" and "physics" mean the same goal.
String? autoClassKey(Node node) {
  final label = node.classLabel?.trim();
  if (label != null && label.isNotEmpty) return label.toLowerCase();
  final id = node.classId?.trim();
  if (id != null && id.isNotEmpty) return id.toLowerCase();
  return null;
}

/// Minutes a task contributes to [window]: recorded time when present,
/// otherwise the already-elapsed part of its calendar block. Future blocks
/// and pure due dates contribute zero, so planned work is never reported
/// as done.
double _taskMinutesInWindow(Node node, AutoGoalWindow window, DateTime now) {
  // Recorded runs are authoritative, even when they fall outside this
  // window: falling back to the planned block would attribute the same
  // work to the wrong period. Sum each run instead of the aggregate
  // actualStart..actualEnd span — the span includes the gap between two
  // sessions, so a 30m morning run plus a 30m afternoon run used to count
  // as hours of "work" in an automated minutes goal.
  final sessions = node.recordedSessions;
  if (sessions.isNotEmpty) {
    var minutes = 0.0;
    for (final session in sessions) {
      minutes += window.overlapMinutes(session.start, session.end);
    }
    return minutes;
  }
  final start = node.schedule?.start;
  final end = node.schedule?.end;
  if (start == null || end == null) return 0;
  final elapsedEnd = end.isAfter(now) ? now : end;
  return window.overlapMinutes(start, elapsedEnd);
}

bool _completedIn(Node node, AutoGoalWindow window) {
  final completed = node.completedAt;
  return node.isDone && completed != null && window.contains(completed);
}

List<Node> _tasksDueInCheckWindow(
  List<Node> pool,
  AutoFacet facet,
  AutoGoalWindow window,
  DateTime now,
) {
  final horizon = facet.horizonDays;
  final start = horizon != null && horizon > 0 ? autoDay(now) : window.start;
  final end = horizon != null && horizon > 0
      ? shiftLocalDay(autoDay(now), horizon + 1)
      : window.end;
  return [
    for (final node in pool)
      if (node.schedule?.due != null &&
          !node.schedule!.due!.isBefore(start) &&
          node.schedule!.due!.isBefore(end))
        node,
  ];
}

bool _moneyMatches(AutoFacet facet, Transaction txn) {
  if (facet.moneyCategories.isEmpty) return true;
  final category = (txn.category ?? '').toLowerCase();
  return facet.moneyCategories.any(
    (raw) => category.contains(raw.trim().toLowerCase()),
  );
}

Set<String> _subtreeIds(String rootId, List<Node> nodes) {
  final byParent = <String, List<Node>>{};
  for (final node in nodes) {
    for (final parent in node.parentIds) {
      byParent.putIfAbsent(parent, () => []).add(node);
    }
  }
  final out = <String>{};
  final queue = <String>[rootId];
  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    for (final child in byParent[current] ?? const <Node>[]) {
      if (out.add(child.id)) queue.add(child.id);
    }
  }
  return out;
}

