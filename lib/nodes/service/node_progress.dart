import '../model/node.dart';

/// Progress of a leaf node given its actuals. Clamped to [0, 1].
/// Money leaves compare actual vs target, effort leaves minutes vs target,
/// plain leaves are binary on [Node.isDone].
double leafProgress(
  Node node, {
  double timeActualMinutes = 0,
  double moneyActual = 0,
}) {
  if (node.money != null) {
    final target = node.money!.effectiveTarget;
    if (target <= 0) return node.isDone ? 1.0 : 0.0;
    return (moneyActual / target).clamp(0.0, 1.0);
  }
  if (node.effort != null) {
    final target = node.effort!.targetMinutes;
    if (target <= 0) return node.isDone ? 1.0 : 0.0;
    return (timeActualMinutes / target).clamp(0.0, 1.0);
  }
  return node.isDone ? 1.0 : 0.0;
}

/// Average aggregation for checklist-style parents.
double childrenProgress(List<double> childValues) {
  if (childValues.isEmpty) return 0.0;
  final sum = childValues.fold<double>(0, (a, b) => a + b);
  return (sum / childValues.length).clamp(0.0, 1.0);
}

/// Progress for every node in a DAG, cycle-safe via the visit stack.
///
/// Aggregation rules (explicit beats computed):
/// - done → 1.0, failed/skipped → 0.0.
/// - Template with instances (habits, recurring budgets): average over
///   instance children — a repetition rate, not a sum. Skipped instances
///   are excluded from the denominator.
/// - Money parent with ordinary children: subtree actuals vs the parent's
///   own target (a $62 grocery run fills a $400 food month). Without its
///   own target, children targets are summed instead.
/// - Effort parent with ordinary children: same shape in minutes.
/// - Plain parents: average of children. Shared children count once per
///   root query.
Map<String, double> progressForest(
  List<Node> nodes, {
  Map<String, double> timeActualByNodeId = const {},
  Map<String, double> moneyActualByNodeId = const {},
}) {
  final byId = {for (final n in nodes) n.id: n};
  final byParent = <String, List<Node>>{};
  for (final n in nodes) {
    for (final p in n.parentIds) {
      byParent.putIfAbsent(p, () => []).add(n);
    }
  }
  final memo = <String, double>{};

  late double Function(Node node, Set<String> stack) compute;
  late double Function(String id, Set<String> stack) visit;
  compute = (Node node, Set<String> stack) {
    if (node.status == NodeStatus.done) return 1.0;
    if (node.status == NodeStatus.failed ||
        node.status == NodeStatus.skipped) {
      return 0.0;
    }
    final kids = byParent[node.id] ?? const <Node>[];
    if (kids.isEmpty) {
      return _leafValue(node,
          timeActualByNodeId: timeActualByNodeId,
          moneyActualByNodeId: moneyActualByNodeId);
    }
    if (kids.any((k) => k.instanceOfId == node.id)) {
      final rated =
          kids.where((k) => k.status != NodeStatus.skipped).toList();
      if (rated.isEmpty) return 0.0;
      return childrenProgress(
          [for (final k in rated) visit(k.id, {...stack})]);
    }
    final moneyFlavor = node.money != null ||
        kids.any((k) => _subtreeHasMoney(k.id, byParent));
    if (moneyFlavor) {
      final target = node.money?.effectiveTarget ??
          kids.fold<double>(
              0,
              (sum, k) =>
                  sum + _subtreeMoneyTarget(k.id, byId, byParent, {}));
      if (target <= 0) {
        return childrenProgress(
            [for (final k in kids) visit(k.id, {...stack})]);
      }
      final actual = _subtreeMoneyActual(
          node.id, byId, byParent, moneyActualByNodeId, {});
      return (actual / target).clamp(0.0, 1.0);
    }
    final effortFlavor = node.effort != null ||
        kids.any((k) => _subtreeHasEffort(k.id, byParent));
    if (effortFlavor) {
      final ownTarget = (node.effort?.targetMinutes ?? 0).toDouble();
      final target = ownTarget != 0
          ? ownTarget
          : kids.fold<double>(
              0,
              (sum, k) =>
                  sum + _subtreeEffortTarget(k.id, byId, byParent, {}));
      if (target <= 0) {
        return childrenProgress(
            [for (final k in kids) visit(k.id, {...stack})]);
      }
      final actual = _subtreeTimeActual(
          node.id, byId, byParent, timeActualByNodeId, {});
      return (actual / target).clamp(0.0, 1.0);
    }
    final rated =
        kids.where((k) => k.status != NodeStatus.skipped).toList();
    if (rated.isEmpty) return 0.0;
    return childrenProgress(
        [for (final k in rated) visit(k.id, {...stack})]);
  };

  visit = (String id, Set<String> stack) {
    final cached = memo[id];
    if (cached != null) return cached;
    final node = byId[id];
    if (node == null) return 0.0;
    if (!stack.add(id)) return 0.0; // cycle guard
    double value;
    try {
      value = compute(node, stack);
    } finally {
      stack.remove(id);
    }
    memo[id] = value;
    return value;
  };

  for (final n in nodes) {
    visit(n.id, <String>{});
  }
  return memo;
}

double _leafValue(
  Node node, {
  required Map<String, double> timeActualByNodeId,
  required Map<String, double> moneyActualByNodeId,
}) {
  if (node.money != null) {
    final target = node.money!.effectiveTarget;
    if (target <= 0) return node.isDone ? 1.0 : 0.0;
    return ((moneyActualByNodeId[node.id] ?? 0) / target).clamp(0.0, 1.0);
  }
  if (node.effort != null) {
    final target = node.effort!.targetMinutes;
    if (target <= 0) return node.isDone ? 1.0 : 0.0;
    return ((timeActualByNodeId[node.id] ?? 0) / target).clamp(0.0, 1.0);
  }
  return node.isDone ? 1.0 : 0.0;
}

// ── Subtree actuals (direct links + recorded actuals, no tags) ────────────

/// Reported minutes for [node] plus all descendants.
double timeActualForNode(Node node, List<Node> all) {
  final byId = {for (final n in all) n.id: n};
  final byParent = <String, List<Node>>{};
  for (final n in all) {
    for (final p in n.parentIds) {
      byParent.putIfAbsent(p, () => []).add(n);
    }
  }
  return _subtreeTimeActual(node.id, byId, byParent, const {}, {});
}

double _subtreeTimeActual(
  String id,
  Map<String, Node> byId,
  Map<String, List<Node>> byParent,
  Map<String, double> overrides,
  Set<String> seen,
) {
  if (!seen.add(id)) return 0.0;
  var total = overrides[id] ?? 0.0;
  final node = byId[id];
  if (node != null) {
    final d = node.reportedDuration;
    if (d != null) total += d.inMinutes.toDouble();
    for (final kid in byParent[id] ?? const <Node>[]) {
      total += _subtreeTimeActual(kid.id, byId, byParent, overrides, seen);
    }
  }
  return total;
}

/// Money actual for [node] plus descendants. The [MoneyFacet.actualAmount]
/// field is the source of truth (set when a transaction is linked);
/// [txnAmountsById] only fills gaps for ad-hoc links to money-less nodes,
/// so linked amounts are never double-counted.
double moneyActualForNode(
  Node node,
  List<Node> all, {
  Map<String, double> txnAmountsById = const {},
}) {
  final byId = {for (final n in all) n.id: n};
  final byParent = <String, List<Node>>{};
  for (final n in all) {
    for (final p in n.parentIds) {
      byParent.putIfAbsent(p, () => []).add(n);
    }
  }
  return _subtreeMoneyActual(
      node.id, byId, byParent, txnAmountsById, {});
}

double _subtreeMoneyActual(
  String id,
  Map<String, Node> byId,
  Map<String, List<Node>> byParent,
  Map<String, double> txnAmountsById,
  Set<String> seen,
) {
  if (!seen.add(id)) return 0.0;
  var total = 0.0;
  final node = byId[id];
  if (node != null) {
    final m = node.money;
    if (m?.actualAmount != null) {
      total += m!.actualAmount!.abs();
    } else if (m != null) {
      for (final txnId in m.linkedTransactionIds) {
        total += (txnAmountsById[txnId] ?? 0).abs();
      }
    }
    for (final kid in byParent[id] ?? const <Node>[]) {
      total +=
          _subtreeMoneyActual(kid.id, byId, byParent, txnAmountsById, seen);
    }
  }
  return total;
}

double _subtreeMoneyTarget(
  String id,
  Map<String, Node> byId,
  Map<String, List<Node>> byParent,
  Set<String> seen,
) {
  if (!seen.add(id)) return 0.0;
  final node = byId[id];
  if (node == null) return 0.0;
  var total = node.money?.effectiveTarget ?? 0.0;
  for (final kid in byParent[id] ?? const <Node>[]) {
    total += _subtreeMoneyTarget(kid.id, byId, byParent, seen);
  }
  return total;
}

double _subtreeEffortTarget(
  String id,
  Map<String, Node> byId,
  Map<String, List<Node>> byParent,
  Set<String> seen,
) {
  if (!seen.add(id)) return 0.0;
  final node = byId[id];
  if (node == null) return 0.0;
  var total = (node.effort?.targetMinutes ?? 0).toDouble();
  for (final kid in byParent[id] ?? const <Node>[]) {
    total += _subtreeEffortTarget(kid.id, byId, byParent, seen);
  }
  return total;
}

bool _subtreeHasMoney(String id, Map<String, List<Node>> byParent) {
  final seen = <String>{};
  final queue = <String>[id];
  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    if (!seen.add(current)) continue;
    for (final kid in byParent[current] ?? const <Node>[]) {
      if (kid.money != null) return true;
      queue.add(kid.id);
    }
  }
  return false;
}

bool _subtreeHasEffort(String id, Map<String, List<Node>> byParent) {
  final seen = <String>{};
  final queue = <String>[id];
  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    if (!seen.add(current)) continue;
    for (final kid in byParent[current] ?? const <Node>[]) {
      if (kid.effort != null) return true;
      queue.add(kid.id);
    }
  }
  return false;
}

/// All descendant ids of [rootId] (cycle-safe).
Set<String> descendantIds(String rootId, List<Node> all) {
  final byParent = <String, List<Node>>{};
  for (final n in all) {
    for (final p in n.parentIds) {
      byParent.putIfAbsent(p, () => []).add(n);
    }
  }
  final out = <String>{};
  final queue = <String>[rootId];
  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    for (final kid in byParent[current] ?? const <Node>[]) {
      if (out.add(kid.id)) queue.add(kid.id);
    }
  }
  return out;
}

/// All ancestor ids of [nodeId] (cycle-safe).
Set<String> ancestorIds(String nodeId, List<Node> all) {
  final byId = {for (final n in all) n.id: n};
  final out = <String>{};
  final queue = <String>[nodeId];
  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    final node = byId[current];
    if (node == null) continue;
    for (final p in node.parentIds) {
      if (out.add(p)) queue.add(p);
    }
  }
  return out;
}

// ── Views as queries ──────────────────────────────────────────────────────

/// Nodes with a calendar block, sorted by start.
List<Node> calendarNodes(List<Node> all) {
  final items = all.where((n) => n.hasCalendarBlock).toList()
    ..sort((a, b) => a.schedule!.start!.compareTo(b.schedule!.start!));
  return items;
}

/// Open nodes with a due date, overdue first then earliest due.
List<Node> priorityQueue(List<Node> all, DateTime now) {
  final items =
      all.where((n) => n.isOpen && n.hasDue).toList()..sort((a, b) {
        final aOver = a.isOverdueAt(now) ? 0 : 1;
        final bOver = b.isOverdueAt(now) ? 0 : 1;
        if (aOver != bOver) return aOver - bOver;
        return a.schedule!.due!.compareTo(b.schedule!.due!);
      });
  return items;
}

/// Nodes carrying money (ledger / waterfall source).
List<Node> ledgerNodes(List<Node> all) =>
    all.where((n) => n.hasMoney).toList();

// ── Solvency simulation ───────────────────────────────────────────────────

class BalancePoint {
  final DateTime date;
  final double balance;
  final String nodeId;
  const BalancePoint(
      {required this.date, required this.balance, required this.nodeId});
}

class SolvencyResult {
  final List<BalancePoint> points;
  final DateTime? firstNegativeDate;
  final double minBalance;
  const SolvencyResult({
    required this.points,
    required this.firstNegativeDate,
    required this.minBalance,
  });

  bool get staysNonNegative => firstNegativeDate == null;
}

/// Project balances from [from] over dated money nodes. Spend/save are
/// outflows, income inflows; concrete actuals beat projections. Save
/// targets without actuals are allocations, not cash movement, and are
/// skipped. Pure function — the ledger view and funding goals share it.
SolvencyResult simulateSolvency({
  required List<Node> all,
  required double startingBalance,
  required DateTime from,
  Map<String, double> txnAmountsById = const {},
}) {
  final flows = <({DateTime date, double amount, String nodeId})>[];
  for (final n in all) {
    final m = n.money;
    if (m == null || n.status == NodeStatus.skipped) continue;
    final date = n.schedule?.due ?? n.schedule?.start ?? n.schedule?.end;
    if (date == null || date.isBefore(from)) continue;
    double? mag = m.actualAmount;
    if (mag == null && m.direction == MoneyDirection.save) continue;
    mag ??= m.effectiveTarget;
    if (mag <= 0) continue;
    var linkedGap = 0.0;
    if (m.actualAmount == null) {
      for (final txnId in m.linkedTransactionIds) {
        linkedGap += (txnAmountsById[txnId] ?? 0).abs();
      }
      if (linkedGap > 0) mag = linkedGap;
    }
    final signed = m.direction == MoneyDirection.income ? mag : -mag;
    flows.add((date: date, amount: signed, nodeId: n.id));
  }
  flows.sort((a, b) => a.date.compareTo(b.date));
  var balance = startingBalance;
  var min = balance;
  DateTime? firstNegative;
  final points = <BalancePoint>[];
  for (final f in flows) {
    balance += f.amount;
    if (balance < min) min = balance;
    if (balance < 0 && firstNegative == null) firstNegative = f.date;
    points.add(
        BalancePoint(date: f.date, balance: balance, nodeId: f.nodeId));
  }
  return SolvencyResult(
      points: points, firstNegativeDate: firstNegative, minBalance: min);
}

// ── Estimate calibration (time + money) ───────────────────────────────────

class EstimateStats {
  final int count;
  final double medianPlanned;
  final double medianActual;
  final double medianBias;
  final double p90Actual;
  final List<String> outlierNodeIds;
  const EstimateStats({
    required this.count,
    required this.medianPlanned,
    required this.medianActual,
    required this.medianBias,
    required this.p90Actual,
    required this.outlierNodeIds,
  });
}

/// Planned-vs-actual calibration for one template's instances. Planned
/// prefers the calendar-block duration, falling back to the effort target;
/// actual is recorded time. Outliers (>1.5× planned) surface off-task work.
EstimateStats estimateStatsForTemplate(String templateId, List<Node> all) {
  final planned = <double>[];
  final actual = <double>[];
  final biases = <double>[];
  final outliers = <String>[];
  for (final n in all) {
    if (n.instanceOfId != templateId || !n.hasReported) continue;
    final p = n.schedule?.plannedDuration?.inMinutes.toDouble() ??
        (n.effort?.targetMinutes ?? 0).toDouble();
    final a = n.reportedDuration!.inMinutes.toDouble();
    if (p <= 0) continue;
    planned.add(p);
    actual.add(a);
    biases.add(a - p);
    if (a > p * 1.5) outliers.add(n.id);
  }
  double median(List<double> vs) {
    if (vs.isEmpty) return 0.0;
    final s = [...vs]..sort();
    final mid = s.length ~/ 2;
    return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
  }

  double p90(List<double> vs) {
    if (vs.isEmpty) return 0.0;
    final s = [...vs]..sort();
    final idx = ((s.length * 0.9).ceil() - 1).clamp(0, s.length - 1);
    return s[idx];
  }

  return EstimateStats(
    count: planned.length,
    medianPlanned: median(planned),
    medianActual: median(actual),
    medianBias: median(biases),
    p90Actual: p90(actual),
    outlierNodeIds: outliers,
  );
}

// ── Rule evaluation ───────────────────────────────────────────────────────

class HomeworkAheadResult {
  final List<Node> dueSoon;
  final List<Node> openDueSoon;
  const HomeworkAheadResult({required this.dueSoon, required this.openDueSoon});
  bool get satisfied => openDueSoon.isEmpty;
  int get doneCount => dueSoon.length - openDueSoon.length;
}

/// "3 days ahead" check: homework nodes (provenance-based, never tags)
/// due within [today, today + horizonDays]. Satisfied when all are done.
/// Vacuously true when nothing is due — the daily instance records history.
HomeworkAheadResult evaluateHomeworkAhead({
  required List<Node> all,
  required DateTime now,
  int horizonDays = 3,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final endExclusive = today.add(Duration(days: horizonDays + 1));
  final dueSoon = all.where((n) {
    if (!n.isHomework || n.isTemplate) return false;
    final due = n.schedule?.due;
    if (due == null) return false;
    final day = DateTime(due.year, due.month, due.day);
    return !day.isBefore(today) && day.isBefore(endExclusive);
  }).toList()
    ..sort((a, b) => a.schedule!.due!.compareTo(b.schedule!.due!));
  return HomeworkAheadResult(
    dueSoon: dueSoon,
    openDueSoon: dueSoon.where((n) => n.isOpen).toList(),
  );
}
