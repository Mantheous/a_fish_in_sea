import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../nodes/model/node.dart';
import '../bloc/tasks_view_options_cubit.dart';
import '../model/task_rule.dart';

/// Reads the Tasks view options, falling back to defaults when the cubit
/// isn't provided (widget tests pump TasksPage standalone).
TasksViewOptionsState viewOptionsOf(BuildContext context) {
  try {
    return context.watch<TasksViewOptionsCubit>().state;
  } catch (_) {
    return const TasksViewOptionsState();
  }
}

/// Applies the active view plus every enabled hide rule to [nodes]. The
/// 'all' view skips matching entirely so the base lists show exactly what
/// they always showed (including done homework); any other view keeps
/// only matching nodes. Hide rules remove their matches on top, whatever
/// the view — hiding always wins.
List<Node> applyTaskViewOptions(
  List<Node> nodes,
  TasksViewOptionsState viewOptions,
  DateTime now,
) {
  var result = nodes;
  final filter = viewOptions.activeFilter;
  if (!filter.isShowAll) {
    result = result.where((n) => filter.matches(n, now)).toList();
  }
  if (viewOptions.hasHidingRule) {
    result = result
        .where((n) => !taskHiddenByRules(viewOptions.rules, n, now))
        .toList();
  }
  return result;
}

/// Tint for one row: the winning rule's color plus its name for the
/// screen-reader label.
class TaskTint {
  final int? colorValue;
  final String label;

  const TaskTint({required this.colorValue, required this.label});
}

/// First-highlight-wins tints over [nodes] (the full store, like the
/// legacy highlight — rows a view hides keep their tint while hidden).
/// Hidden and done rows never tint.
Map<String, TaskTint> taskTintMap(
  Iterable<Node> nodes,
  TasksViewOptionsState viewOptions,
  DateTime now,
) {
  if (!viewOptions.hasHighlightRule) return const {};
  final tints = <String, TaskTint>{};
  for (final node in nodes) {
    final outcome = evaluateTaskRules(viewOptions.rules, node, now);
    final tint = outcome.tint;
    if (tint == null) continue;
    tints[node.id] = TaskTint(
      colorValue: tint.colorValue,
      label: tint.name,
    );
  }
  return tints;
}
