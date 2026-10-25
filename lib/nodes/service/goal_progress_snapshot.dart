import '../../finances/model/transaction.dart';
import '../model/node.dart';
import 'auto_goal.dart';
import 'goal_completion.dart';
import 'node_progress.dart';

/// One build's worth of goal-progress data: the goal subset, per-goal
/// completion ([progressForest]), the automated readings that fed it, and
/// the goal-child count per parent.
///
/// Home's favorite rows and the Nodes page both read from the same
/// snapshot so a goal never shows a different percentage on two surfaces.
class GoalProgressSnapshot {
  /// Goal-tree subset of the store ([goalNodes]). Homework imports and
  /// personal calendar links live in Tasks/Calendar and are excluded.
  final List<Node> goals;

  /// Goal id → node, and parent id → goal children (shared DAG indexes).
  final Map<String, Node> byId;
  final Map<String, List<Node>> byParent;

  /// Transaction amount per transaction id, kept for tiles that show
  /// money lines (signed amounts, as persisted).
  final Map<String, double> txnAmountsById;

  /// Money actuals per node id: recorded amount first, then linked and
  /// assigned transactions. This is the map [progressForest] consumed.
  final Map<String, double> moneyActualByNodeId;

  /// Percent complete in 0–1 per goal id.
  final Map<String, double> progress;

  /// Every metric reading for every metric goal, in display order.
  final Map<String, GoalMetricsReading> metricReadings;

  /// Derived completion per goal (metric goals and containers).
  final Map<String, GoalCompletion> completion;

  /// Primary metric reading per goal, kept for existing tiles.
  final Map<String, AutoGoalReading> autoReadings;

  const GoalProgressSnapshot({
    required this.goals,
    required this.byId,
    required this.byParent,
    required this.txnAmountsById,
    required this.moneyActualByNodeId,
    required this.progress,
    required this.metricReadings,
    required this.completion,
    required this.autoReadings,
  });

  /// Clamped 0–1 completion. Goals outside the snapshot (homework, unknown
  /// ids) read as 0 rather than throwing.
  double progressOf(String id) => (progress[id] ?? 0).clamp(0.0, 1.0);
  /// Number of goal children. Homework children never count as steps.
  int childCountOf(String id) => byParent[id]?.length ?? 0;

  AutoGoalReading? readingOf(String id) => autoReadings[id];

  GoalMetricsReading? metricsOf(String id) => metricReadings[id];

  GoalCompletion? completionOf(String id) => completion[id];

  double moneyActualOf(String id) {
    final node = byId[id];
    if (node == null) return 0;
    return moneyActualForNodeIndexed(
      node,
      byId: byId,
      byParent: byParent,
      txnAmountsById: moneyActualByNodeId,
    );
  }

  double timeActualOf(String id) {
    final node = byId[id];
    if (node == null) return 0;
    return timeActualForNodeIndexed(node, byId: byId, byParent: byParent);
  }

  double ankiActualOf(String id) {
    final node = byId[id];
    if (node == null) return 0;
    return ankiActualForNodeIndexed(node, byId: byId, byParent: byParent);
  }
}

/// Builds a [GoalProgressSnapshot] from the full node store.
///
/// Automated readings always see every node (homework imports are exactly
/// what a homework goal must measure), while progress is aggregated over
/// the goal tree only.
GoalProgressSnapshot buildGoalProgressSnapshot({
  required List<Node> nodes,
  required List<Transaction> transactions,
  required DateTime now,
}) {
  final goals = goalNodes(nodes);
  final txnAmounts = {for (final t in transactions) t.id: t.amount};
  // Money actuals keyed by node id: a recorded actualAmount wins, plus
  // linked and assigned-transaction sums for nodes without one (audit
  // gaps). Txn-id entries are kept too so linkedTransactionIds fallbacks
  // in progress math keep resolving.
  final assignedSums = <String, double>{};
  for (final t in transactions) {
    final nid = t.assignedNodeId;
    if (nid == null) continue;
    assignedSums[nid] = (assignedSums[nid] ?? 0) + t.amount.abs();
  }
  final moneyActualByNodeId = <String, double>{...txnAmounts};
  for (final n in goals) {
    final recorded = n.money?.actualAmount?.abs();
    if (recorded != null) {
      moneyActualByNodeId[n.id] = recorded;
      continue;
    }
    var sum = 0.0;
    for (final txnId in n.money?.linkedTransactionIds ?? const <String>[]) {
      sum += (txnAmounts[txnId] ?? 0).abs();
    }
    // Assigned sums may duplicate linked ids (link + assign happen
    // together), so only count assigned txns not already linked.
    final linked = n.money?.linkedTransactionIds.toSet() ?? const <String>{};
    for (final t in transactions) {
      if (t.assignedNodeId == n.id && !linked.contains(t.id)) {
        sum += t.amount.abs();
      }
    }
    if (sum > 0) moneyActualByNodeId[n.id] = sum;
  }
  // Assigned-only nodes (no facet amount yet) still report.
  for (final entry in assignedSums.entries) {
    moneyActualByNodeId.putIfAbsent(entry.key, () => entry.value);
  }
  final timeActualByNodeId = <String, double>{
    for (final n in goals)
      if (n.reportedDuration != null)
        n.id: n.reportedDuration!.inMinutes.toDouble(),
  };
  final metricReadings = metricReadingsForNodes(
    nodes,
    now: now,
    transactions: transactions,
  );
  final autoReadings = {
    for (final entry in metricReadings.entries)
      if (entry.value.primary != null) entry.key: entry.value.primary!,
  };
  final progress = progressForest(
    goals,
    moneyActualByNodeId: moneyActualByNodeId,
    timeActualByNodeId: timeActualByNodeId,
    autoProgressByNodeId: {
      for (final entry in metricReadings.entries)
        entry.key: entry.value.progress,
    },
  );
  final completion = goalCompletionForest(goals, readings: metricReadings);
  final indexes = buildNodeIndexes(goals);
  return GoalProgressSnapshot(
    goals: goals,
    byId: indexes.byId,
    byParent: indexes.byParent,
    txnAmountsById: txnAmounts,
    moneyActualByNodeId: moneyActualByNodeId,
    progress: progress,
    metricReadings: metricReadings,
    completion: completion,
    autoReadings: autoReadings,
  );
}
