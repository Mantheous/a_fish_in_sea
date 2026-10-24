import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';

import '../model/node.dart';
import 'auto_goal_format.dart';

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

  int get days => end.difference(start).inDays;

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
DateTime autoDay(DateTime at) => DateTime(at.year, at.month, at.day);

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
      return AutoGoalWindow(start: day, end: day.add(const Duration(days: 1)));
    case TimeScale.weekly:
      final start = day.subtract(Duration(days: day.weekday - 1));
      return AutoGoalWindow(
        start: start,
        end: start.add(const Duration(days: 7)),
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
  final diff = day.difference(anchorDay).inDays;
  final index = (diff / days).floor();
  final start = anchorDay.add(Duration(days: index * days));
  return AutoGoalWindow(
    start: start,
    end: start.add(Duration(days: days)),
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
  });

  String get actualLabel => formatAutoValue(facet.metric, actual);
  String get targetLabel => formatAutoValue(facet.metric, target);

  /// "6h 20m / 7h" or "$14.20 / $20.00".
  String get summary => '$actualLabel / $targetLabel';

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
}) {
  final facet = goal.auto;
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

  switch (facet.source) {
    case AutoSource.tasks:
      final pool = _taskPool(goal, facet, nodes);
      switch (facet.metric) {
        case AutoMetric.minutes:
        case AutoMetric.averageMinutes:
          final days = <DateTime>{};
          for (final node in pool) {
            final minutes = _taskMinutesInWindow(node, window, when);
            if (minutes <= 0) continue;
            actual += minutes;
            matched++;
            final anchor =
                node.actualStart ?? node.schedule?.start ?? node.schedule?.due;
            if (anchor != null) days.add(autoDay(anchor));
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
          actual = 0;
      }
  }

  final target = facet.target;
  final progress = _progress(facet, actual, target);
  final satisfied =
      target > 0 &&
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
  );
}

/// Readings for every automated goal in [nodes], keyed by node id.
Map<String, AutoGoalReading> autoReadingsForNodes(
  List<Node> nodes, {
  required DateTime now,
  List<Transaction> transactions = const [],
}) {
  return {
    for (final node in nodes)
      if (node.auto != null)
        node.id: evaluateAutoGoal(
          node,
          now: now,
          nodes: nodes,
          transactions: transactions,
        ),
  };
}

double _progress(AutoFacet facet, double actual, double target) {
  if (target <= 0) return 0;
  if (facet.metric == AutoMetric.percentDone) {
    return (actual / 100).clamp(0.0, 1.0);
  }
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
          (ids == null || ids.contains(node.id)) &&
          (!facet.homeworkOnly || node.isHomework) &&
          _classMatches(node, keys))
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
  // A reported span is authoritative, even when it falls outside this
  // window: falling back to the planned block would attribute the same
  // work to the wrong period.
  if (node.actualStart != null && node.actualEnd != null) {
    return window.overlapMinutes(node.actualStart, node.actualEnd);
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
      ? autoDay(now).add(Duration(days: horizon + 1))
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

