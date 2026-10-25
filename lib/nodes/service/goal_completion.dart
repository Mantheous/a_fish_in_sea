import '../model/node.dart';
import 'auto_goal.dart';

/// How a goal's completion is decided.
///
/// - Metric goals: every metric must pass. Metrics are statistics; none is
///   a special "guardrail" role. Metrics define completion even when the
///   goal has children (a time goal does not need its event tiles ticked).
///   A container that also needs its work done gets an explicit AllDone
///   metric (the editor adds one before a cap on a container).
/// - Container goals with no metrics: every active child must be complete.
/// - Checklist leaves: the stored check mark ([Node.isDone]).
///
/// Completion is derived for metric/container goals. We never write
/// `status = done` from an observation: a newly imported assignment must
/// be able to reopen a parent without a separate reopen rule. A stored
/// `done` remains a user assertion and still counts as an override.
class GoalCompletion {
  final bool complete;

  /// True when the value was computed (metric/container). False for a
  /// checklist leaf, whose checkbox is the source of truth.
  final bool derived;

  /// Number of active children that contributed to a container result.
  final int childCount;

  const GoalCompletion({
    required this.complete,
    required this.derived,
    this.childCount = 0,
  });

  static const checklistOpen = GoalCompletion(complete: false, derived: false);
}

/// Per-goal derived completion for the goal tree.
///
/// [goals] should be [goalNodes] (homework imports excluded), but class
/// nodes are regular goals and stay in. Metric readings must cover every
/// metric goal; a missing reading counts as incomplete rather than
/// silently passing.
Map<String, GoalCompletion> goalCompletionForest(
  List<Node> goals, {
  Map<String, GoalMetricsReading> readings = const {},
}) {
  final byId = {for (final node in goals) node.id: node};
  final byParent = <String, List<Node>>{};
  for (final node in goals) {
    for (final parent in node.parentIds) {
      byParent.putIfAbsent(parent, () => []).add(node);
    }
  }
  final memo = <String, GoalCompletion>{};

  late GoalCompletion Function(String id, Set<String> stack) visit;
  visit = (String id, Set<String> stack) {
    final cached = memo[id];
    if (cached != null) return cached;
    final node = byId[id];
    if (node == null) return GoalCompletion.checklistOpen;
    if (!stack.add(id)) return GoalCompletion.checklistOpen;
    GoalCompletion result;
    try {
      result = _compute(node, byParent, readings, stack, visit);
    } finally {
      stack.remove(id);
    }
    memo[id] = result;
    return result;
  };

  for (final node in goals) {
    visit(node.id, <String>{});
  }
  return memo;
}

GoalCompletion _compute(
  Node node,
  Map<String, List<Node>> byParent,
  Map<String, GoalMetricsReading> readings,
  Set<String> stack,
  GoalCompletion Function(String id, Set<String> stack) visit,
) {
  if (node.isUnbounded || node.status == NodeStatus.failed) {
    return GoalCompletion(
      complete: false,
      derived: node.hasMetrics || (byParent[node.id]?.isNotEmpty ?? false),
    );
  }
  if (node.isTemplate) {
    // A recurring template's instances are a repetition history, not a
    // finite container; completing it would mean "every future instance
    // done". It keeps showing its average instead.
    return const GoalCompletion(complete: false, derived: false);
  }
  final kids = [
    for (final kid in byParent[node.id] ?? const <Node>[])
      if (kid.status != NodeStatus.skipped && !kid.isUnbounded) kid,
  ];
  // Metrics define completion when present. A time goal's reported
  // session is work even when its child tile was never manually ticked;
  // containers that need "all work done" get an explicit AllDone metric.
  // A class child is the exception: a Homework goal with a legacy cap
  // metric still has to finish its classes.
  if (node.hasMetrics) {
    var complete = node.isDone || (readings[node.id]?.satisfied ?? false);
    if (kids.any((kid) => kid.isClassNode)) {
      for (final kid in kids) {
        if (!visit(kid.id, stack).complete) {
          complete = false;
          break;
        }
      }
    }
    return GoalCompletion(complete: complete, derived: true);
  }
  if (kids.isEmpty) {
    return GoalCompletion(complete: node.isDone, derived: false);
  }
  var childrenComplete = true;
  for (final kid in kids) {
    final child = visit(kid.id, stack);
    if (!child.complete) {
      childrenComplete = false;
      break;
    }
  }
  return GoalCompletion(
    complete: node.isDone || childrenComplete,
    derived: true,
    childCount: kids.length,
  );
}
