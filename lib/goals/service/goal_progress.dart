import '../model/goal.dart';

double leafProgress(Goal goal, {double actual = 0}) {
  switch (goal.type) {
    case GoalType.checklist:
      return goal.done ? 1.0 : 0.0;
    case GoalType.time:
      final target = goal.targetMinutes ?? 0;
      if (target <= 0) return goal.done ? 1.0 : 0.0;
      return (actual / target).clamp(0.0, 1.0);
    case GoalType.financial:
      final target = goal.effectiveAmount;
      if (target <= 0) return goal.done ? 1.0 : 0.0;
      return (actual / target).clamp(0.0, 1.0);
  }
}

double childrenProgress(List<double> childValues) {
  if (childValues.isEmpty) return 0.0;
  final sum = childValues.fold<double>(0, (a, b) => a + b);
  return (sum / childValues.length).clamp(0.0, 1.0);
}

Map<String, double> progressForest(
  List<Goal> goals,
  Map<String, double> actualByGoalId,
) {
  final byId = {for (final g in goals) g.id: g};
  final byParent = <String?, List<Goal>>{};
  for (final g in goals) {
    byParent.putIfAbsent(g.parentId, () => []).add(g);
  }
  final memo = <String, double>{};

  double visit(String id) {
    final cached = memo[id];
    if (cached != null) return cached;
    final goal = byId[id];
    if (goal == null) return 0.0;
    final kids = byParent[id] ?? const <Goal>[];
    final value = kids.isEmpty
        ? leafProgress(goal, actual: actualByGoalId[id] ?? 0)
        : childrenProgress([for (final k in kids) visit(k.id)]);
    memo[id] = value;
    return value;
  }

  for (final g in goals) {
    visit(g.id);
  }
  return memo;
}
