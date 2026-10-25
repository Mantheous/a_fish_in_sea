import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/model/node.dart';
import '../../nodes/service/auto_goal.dart';
import '../../nodes/service/goal_completion.dart';
import '../../nodes/service/goal_progress_snapshot.dart';
import '../../nodes/view/node_checkbox.dart';

final _favoriteDueFormat = DateFormat('EEE, MMM d');

/// One row in Home's Favorite goals section.
///
/// A star is set on the goal tree, but a favorite is a glance row: goals
/// whose completion is measured from data — automated goals, money /
/// effort / Anki facets, repeating templates, rule goals — report their
/// progress instead of a checkbox. Any goal with subgoals also shows the
/// progress it rolls up. Only a genuinely tickable goal (no facets, no
/// rule, no children) keeps a checkbox and no progress bar.
class FavoriteGoalLine extends StatelessWidget {
  final Node node;
  final DateTime now;

  /// Progress for the whole goal tree, hoisted by the Home page so the
  /// rows share one aggregation pass.
  final GoalProgressSnapshot snapshot;

  const FavoriteGoalLine({
    super.key,
    required this.node,
    required this.now,
    required this.snapshot,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The Home page already rebuilds on NodeCubit changes; resolve without
    // another full-list watch per row.
    final live = context.read<NodeCubit>().byId(node.id) ?? node;
    final childCount = snapshot.childCountOf(live.id);
    final value = snapshot.progressOf(live.id);
    final reading = snapshot.readingOf(live.id);
    final completion = snapshot.completionOf(live.id);
    final failed = live.status == NodeStatus.failed;
    final checkboxGoal =
        _isCheckboxGoal(live) && completion?.derived != true;
    final showsProgress =
        !live.isUnbounded && (!checkboxGoal || childCount > 0);
    final statusColor = failed || live.isOverdueAt(now)
        ? theme.colorScheme.error
        : null;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: checkboxGoal
          ? NodeCheckbox(node: live)
          : _leadingIcon(context, live, value, completion),
      title: Text(
        live.title,
        style: live.isDone || failed
            ? TextStyle(
                decoration: TextDecoration.lineThrough,
                color: failed ? theme.colorScheme.error : null,
              )
            : null,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _subtitle(live, childCount, reading, failed),
            style: theme.textTheme.labelSmall?.copyWith(color: statusColor),
          ),
          if (showsProgress) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(value: value, minHeight: 3),
          ],
        ],
      ),
    );
  }

  /// A checkbox is only honest when nothing else measures the goal. A
  /// plain parent keeps its checkbox (you can still finish it outright)
  /// and gains the progress bar below.
  static bool _isCheckboxGoal(Node node) =>
      !node.isUnbounded &&
      !node.isAutomatedGoal &&
      node.money == null &&
      node.effort == null &&
      node.anki == null &&
      !node.isTemplate &&
      (node.rule == null || node.rule!.kind == NodeRuleKind.none);

  /// Mirrors the Nodes-page leading icons so one goal reads the same on
  /// both surfaces. The percentage is in the tooltip and the bar below.
  Widget _leadingIcon(
    BuildContext context,
    Node live,
    double value,
    GoalCompletion? completion,
  ) {
    final theme = Theme.of(context);
    final color = live.status == NodeStatus.failed
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    if (live.isUnbounded) {
      return const Tooltip(
        message: 'Unbounded goal — ongoing, no checkbox',
        child: Icon(Icons.all_inclusive, size: 24),
      );
    }
    if (completion?.derived == true) {
      final complete = completion!.complete;
      return Tooltip(
        message: complete
            ? 'Complete — all work/metrics pass'
            : 'Incomplete — open work or metrics remain',
        child: Icon(
          complete ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 24,
          color: complete ? color : theme.colorScheme.outline,
        ),
      );
    }
    final percent = '${(value * 100).round()}%';
    final (IconData icon, String label) = switch (live) {
      Node(isAutomatedGoal: true) => (
        Icons.auto_graph,
        'Automated goal — measured from your data',
      ),
      Node(isTemplate: true) => (Icons.repeat_outlined, 'Repeating goal'),
      Node(rule: final rule?) when rule.kind != NodeRuleKind.none => (
        Icons.auto_awesome_outlined,
        'Rule goal — measured from your data',
      ),
      Node(money: _?) => (Icons.savings_outlined, 'Savings goal'),
      Node(effort: _?) => (Icons.timer_outlined, 'Time goal'),
      Node(anki: _?) => (Icons.school_outlined, 'Review goal'),
      _ => (Icons.flag_outlined, 'Goal'),
    };
    return Tooltip(
      message: '$label · $percent complete',
      child: Icon(icon, size: 24, color: color),
    );
  }

  /// "Due today · 3 steps · 4h 20m / 7h · 60%". Unbounded goals show
  /// neither dates nor a percentage — they are ongoing directions.
  String _subtitle(
    Node live,
    int childCount,
    AutoGoalReading? reading,
    bool failed,
  ) {
    if (live.isUnbounded) {
      return childCount == 0
          ? 'unbounded'
          : 'unbounded · ${_steps(childCount)}';
    }
    final parts = <String>[];
    if (failed) {
      parts.add('Failed');
    } else if (live.isOverdueAt(now)) {
      parts.add('Overdue');
    } else {
      final due = live.schedule?.due;
      if (due != null) {
        final today = DateTime(now.year, now.month, now.day);
        final dueDay = DateTime(due.year, due.month, due.day);
        parts.add(
          dueDay == today
              ? 'Due today'
              : 'due ${_favoriteDueFormat.format(due)}',
        );
      }
    }
    if (childCount > 0) parts.add(_steps(childCount));
    final measure = _measure(live, reading);
    if (measure != null) parts.add(measure);
    if (_isCheckboxGoal(live) && childCount == 0) {
      // A plain leaf is just a checkbox: the status line is the whole row.
      return parts.isEmpty ? 'open' : parts.join(' · ');
    }
    // percentDone already reads as a percentage; don't print it twice.
    if (reading?.facet.metric != AutoMetric.percentDone) {
      parts.add('${(snapshot.progressOf(live.id) * 100).round()}%');
    }
    return parts.isEmpty ? '0%' : parts.join(' · ');
  }

  /// Actual vs target in the facet's own units, or null for plain goals.
  String? _measure(Node live, AutoGoalReading? reading) {
    if (reading != null) return reading.summary;
    if (live.money != null) {
      final actual = snapshot.moneyActualOf(live.id);
      final target = live.money!.effectiveTarget;
      return '\$${actual.toStringAsFixed(2)} / \$${target.toStringAsFixed(2)}';
    }
    if (live.effort != null) {
      final actual = snapshot.timeActualOf(live.id);
      return '${actual.toStringAsFixed(0)}m / '
          '${live.effort!.targetMinutes}m';
    }
    if (live.anki != null) {
      final actual = snapshot.ankiActualOf(live.id);
      return '${actual.toStringAsFixed(0)} / '
          '${live.anki!.targetReviews} reviews';
    }
    return null;
  }

  static String _steps(int count) => '$count step${count == 1 ? '' : 's'}';
}
