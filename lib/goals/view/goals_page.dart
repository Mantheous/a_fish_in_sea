import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import 'package:a_fish_in_sea/common/undo/undo_bar.dart';
import 'package:a_fish_in_sea/finances/bloc/budget_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/expense_cubit.dart';
import 'package:a_fish_in_sea/finances/model/budget.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/goals/bloc/goal_cubit.dart';
import 'package:a_fish_in_sea/goals/bloc/tag_cubit.dart';
import 'package:a_fish_in_sea/goals/model/goal.dart';
import 'package:a_fish_in_sea/goals/service/goal_progress.dart';
import 'package:a_fish_in_sea/goals/service/goal_reporting.dart';
import 'package:a_fish_in_sea/navigation/view/app_drawer.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/task_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'goal_editor.dart';

class GoalsPage extends StatefulWidget {
  const GoalsPage({super.key});

  @override
  State<GoalsPage> createState() => _GoalsPageState();
}

class _GoalsPageState extends State<GoalsPage> {
  DeadlineBucket _bucket = DeadlineBucket.all;
  String? _tagFilter;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Goals'),
        actions: const [UndoRedoActions()],
      ),
      drawer: const AppDrawer(),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showGoalEditor(context),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          const _BudgetImportBanner(),
          _FilterRow(
            bucket: _bucket,
            tagFilter: _tagFilter,
            onBucket: (b) => setState(() => _bucket = b),
            onTag: (t) => setState(() => _tagFilter = t),
          ),
          Expanded(child: _GoalTree(
            bucket: _bucket,
            tagFilter: _tagFilter,
          )),
        ],
      ),
    );
  }
}

class _BudgetImportBanner extends StatelessWidget {
  const _BudgetImportBanner();

  @override
  Widget build(BuildContext context) {
    final List<Budget> budgets;
    try {
      budgets = context.watch<BudgetCubit>().state;
    } catch (_) {
      return const SizedBox.shrink();
    }
    if (budgets.isEmpty) return const SizedBox.shrink();
    final goals = context.watch<GoalCubit>().state;
    final hasFinancial = goals.any((g) => g.type == GoalType.financial);
    if (hasFinancial) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Card(
        child: ListTile(
          leading: const Icon(Icons.savings_outlined),
          title: Text('${budgets.length} budgets can move to Goals'),
          subtitle: const Text(
              'Import them as financial goals. Budgets stay put until removed.'),
          trailing: TextButton(
            onPressed: () =>
                context.read<GoalCubit>().importBudgets(budgets),
            child: const Text('Import'),
          ),
        ),
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  final DeadlineBucket bucket;
  final String? tagFilter;
  final ValueChanged<DeadlineBucket> onBucket;
  final ValueChanged<String?> onTag;

  const _FilterRow({
    required this.bucket,
    required this.tagFilter,
    required this.onBucket,
    required this.onTag,
  });

  @override
  Widget build(BuildContext context) {
    final tags = context.watch<TagCubit>().state;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          DropdownButton<DeadlineBucket>(
            value: bucket,
            items: const [
              DropdownMenuItem(
                  value: DeadlineBucket.all, child: Text('All')),
              DropdownMenuItem(
                  value: DeadlineBucket.shortTerm,
                  child: Text('Short-term')),
              DropdownMenuItem(
                  value: DeadlineBucket.longTerm, child: Text('Long-term')),
              DropdownMenuItem(
                  value: DeadlineBucket.overdue, child: Text('Overdue')),
            ],
            onChanged: (b) {
              if (b != null) onBucket(b);
            },
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButton<String?>(
              value: tagFilter,
              isExpanded: true,
              hint: const Text('All tags'),
              items: [
                const DropdownMenuItem(value: null, child: Text('All tags')),
                for (final t in tags)
                  DropdownMenuItem(value: t.id, child: Text(t.name)),
              ],
              onChanged: onTag,
            ),
          ),
          IconButton(
            tooltip: 'Manage tags',
            icon: const Icon(Icons.label_outline),
            onPressed: () => showTagEditor(context),
          ),
        ],
      ),
    );
  }
}

class _GoalTree extends StatelessWidget {
  final DeadlineBucket bucket;
  final String? tagFilter;

  const _GoalTree({required this.bucket, required this.tagFilter});

  @override
  Widget build(BuildContext context) {
    final goals = context.watch<GoalCubit>().state;
    final tags = context.watch<TagCubit>().state;
    if (goals.isEmpty) return const _EmptyGoals();

    final now = DateTime.now();
    bool visible(Goal g) {
      if (tagFilter != null && !g.tagIds.contains(tagFilter)) return false;
      if (bucket == DeadlineBucket.all) return true;
      return bucketFor(g.deadline, now) == bucket;
    }

    final actuals = _actualsFor(context, goals);
    final progress = progressForest(goals, actuals);
    final tagNames = {for (final t in tags) t.id: t.name};

    final roots =
        goals.where((g) => g.parentId == null && visible(g)).toList()
          ..sort((a, b) => a.deadline.compareTo(b.deadline));
    if (roots.isEmpty) return const _EmptyGoals();
    final tagged = roots.where((g) => g.tagIds.isNotEmpty).toList();
    final untagged = roots.where((g) => g.tagIds.isEmpty).toList();

    return ListView(
      padding: const EdgeInsets.only(bottom: 80),
      children: [
        for (final g in tagged)
          _GoalNode(
              goal: g,
              goals: goals,
              progress: progress,
              tagNames: tagNames,
              visible: visible,
              depth: 0),
        if (untagged.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Finish all tasks',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          for (final g in untagged)
            _GoalNode(
                goal: g,
                goals: goals,
                progress: progress,
                tagNames: tagNames,
                visible: visible,
                depth: 0),
        ],
      ],
    );
  }

  Map<String, double> _actualsFor(BuildContext context, List<Goal> goals) {
    final events = context.watch<CalendarCubit>().state;
    final tasks = context.watch<TaskCubit>().state;
    final reporting = context.watch<ReportingCubit>().state;
    final entries = [for (final l in reporting.values) ...l];
    final expenses = context.watch<ExpenseCubit>().state;
    final transactions = context.watch<TransactionsCubit>().state;
    final tags = context.read<TagCubit>().state;
    final out = <String, double>{};
    for (final g in goals) {
      if (g.type == GoalType.time) {
        out[g.id] = timeActualForGoal(
            goal: g, events: events, tasks: tasks, entries: entries);
      } else if (g.type == GoalType.financial) {
        out[g.id] = financialActualForGoal(
            goal: g,
            expenses: expenses,
            transactions: transactions,
            allTags: tags);
      }
    }
    return out;
  }
}

class _GoalNode extends StatelessWidget {
  final Goal goal;
  final List<Goal> goals;
  final Map<String, double> progress;
  final Map<String, String> tagNames;
  final bool Function(Goal) visible;
  final int depth;

  const _GoalNode({
    required this.goal,
    required this.goals,
    required this.progress,
    required this.tagNames,
    required this.visible,
    required this.depth,
  });

  @override
  Widget build(BuildContext context) {
    final kids =
        goals.where((g) => g.parentId == goal.id && visible(g)).toList()
          ..sort((a, b) => a.deadline.compareTo(b.deadline));
    final value = progress[goal.id] ?? 0;
    final dateFmt = DateFormat('MMM d, y');
    final tagLabels = [
      for (final id in goal.tagIds) tagNames[id] ?? 'tag'
    ];
    final tile = ListTile(
      contentPadding:
          EdgeInsets.only(left: 16 + depth * 20, right: 8),
      leading: goal.type == GoalType.checklist
          ? Checkbox(
              value: goal.done,
              onChanged: (_) =>
                  context.read<GoalCubit>().toggleDone(goal.id),
            )
          : Icon(
              goal.type == GoalType.time
                  ? Icons.timer_outlined
                  : Icons.savings_outlined,
              color: goal.failed ? Colors.red : null,
            ),
      title: Text(
        goal.title,
        style: TextStyle(
          decoration: goal.done
              ? TextDecoration.lineThrough
              : goal.failed
                  ? TextDecoration.lineThrough
                  : null,
          color: goal.failed ? Colors.red : null,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              '${goal.type.name} · due ${dateFmt.format(goal.deadline)} · ${(value * 100).round()}%'),
          if (tagLabels.isNotEmpty)
            Wrap(
              spacing: 4,
              children: [for (final l in tagLabels) Chip(label: Text(l))],
            ),
          LinearProgressIndicator(value: value),
        ],
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (choice) {
          final cubit = context.read<GoalCubit>();
          switch (choice) {
            case 'edit':
              showGoalEditor(context, existing: goal);
            case 'toggle':
              cubit.toggleDone(goal.id);
            case 'fail':
              cubit.setFailed(goal.id, !goal.failed);
            case 'delete':
              cubit.deleteGoal(goal.id);
          }
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'toggle', child: Text('Toggle done')),
          PopupMenuItem(value: 'fail', child: Text('Toggle failed')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
      onTap: () => showGoalEditor(context, existing: goal),
    );
    if (kids.isEmpty) return tile;
    return ExpansionTile(
      tilePadding:
          EdgeInsets.only(left: 16 + depth * 20, right: 8),
      leading: goal.type == GoalType.checklist
          ? Checkbox(
              value: goal.done,
              onChanged: (_) =>
                  context.read<GoalCubit>().toggleDone(goal.id),
            )
          : Icon(goal.type == GoalType.time
              ? Icons.timer_outlined
              : Icons.savings_outlined),
      title: Text(goal.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              '${goal.type.name} · due ${dateFmt.format(goal.deadline)} · ${(value * 100).round()}%'),
          LinearProgressIndicator(value: value),
        ],
      ),
      children: [
        for (final k in kids)
          _GoalNode(
              goal: k,
              goals: goals,
              progress: progress,
              tagNames: tagNames,
              visible: visible,
              depth: depth + 1),
      ],
    );
  }
}

class _EmptyGoals extends StatelessWidget {
  const _EmptyGoals();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.flag_outlined, size: 48),
          const SizedBox(height: 8),
          Text('No goals yet',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Add one with the + button'),
        ],
      ),
    );
  }
}
