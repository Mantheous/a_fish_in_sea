import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/navigation/view/app_drawer.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_progress.dart';
import 'package:a_fish_in_sea/nodes/view/node_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

/// Management page with two tabs: recurring money templates and budgets.
///
/// Both are unified nodes with a money facet: templates carry a
/// recurrence and generate dated instances; budgets track actuals vs
/// target in the current period. No categories or tags — identity is
/// ancestry.
class RulesAndBudgetsPage extends StatelessWidget {
  const RulesAndBudgetsPage({super.key, this.showDrawer = true});

  final bool showDrawer;

  static final _currFmt = NumberFormat.currency(symbol: '\$');

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        drawer: showDrawer ? const AppDrawer() : null,
        appBar: AppBar(
          title: const Text('Rules & Budgets'),
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.repeat), text: 'Recurring'),
            Tab(icon: Icon(Icons.pie_chart_outline), text: 'Budgets'),
          ]),
        ),
        body: const TabBarView(children: [
          _RecurringTab(),
          _BudgetsTab(),
        ]),
      ),
    );
  }
}

class _RecurringTab extends StatelessWidget {
  const _RecurringTab();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NodeCubit, List<Node>>(
      builder: (context, nodes) {
        final templates = nodes
            .where((n) => n.isTemplate && n.money != null)
            .toList();
        return Column(children: [
          Expanded(
            child: templates.isEmpty
                ? const Center(
                    child: Text(
                        'No recurring templates yet.\nTap + to add one.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey)))
                : ListView.separated(
                    itemCount: templates.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final t = templates[i];
                      final m = t.money!;
                      final sign = m.direction == MoneyDirection.income
                          ? '+'
                          : '−';
                      return ListTile(
                        title: Text(t.title),
                        subtitle: Text(
                            '$sign${RulesAndBudgetsPage._currFmt.format(m.targetAmount)} · ${t.recurrence!.frequency.displayName}'),
                        trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () => showNodeEditor(context,
                                      existing: t)),
                              IconButton(
                                  icon:
                                      const Icon(Icons.delete_outline),
                                  onPressed: () => context
                                      .read<NodeCubit>()
                                      .deleteNode(t.id)),
                            ]),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Add Recurring'),
                  onPressed: () => showNodeEditor(context,
                      enableMoney: true, enableRecurrence: true),
                )),
          ),
        ]);
      },
    );
  }
}

class _BudgetsTab extends StatelessWidget {
  const _BudgetsTab();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BlocBuilder<NodeCubit, List<Node>>(
      builder: (context, nodes) {
        final budgets = nodes
            .where((n) =>
                n.money != null &&
                !n.isTemplate &&
                n.money!.period != null)
            .toList();
        if (budgets.isEmpty) {
          return Column(children: [
            const Expanded(
              child: Center(
                  child: Text(
                      'No budgets yet.\nTap + to add one.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey))),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Add Budget'),
                    onPressed: () =>
                        showNodeEditor(context, enableMoney: true),
                  )),
            ),
          ]);
        }
        return Column(children: [
          Expanded(
            child: ListView.separated(
              itemCount: budgets.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final b = budgets[i];
                final spent = moneyActualForNode(b, nodes);
                final target = b.money!.effectiveTarget;
                final progress = target > 0
                    ? (spent / target).clamp(0.0, 2.0)
                    : 0.0;
                final over = spent > target;
                return ListTile(
                  title: Text(b.title),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${RulesAndBudgetsPage._currFmt.format(spent)} / ${RulesAndBudgetsPage._currFmt.format(target)} · ${b.money!.period!.displayName}',
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress.clamp(0.0, 1.0),
                          backgroundColor:
                              theme.colorScheme.surfaceContainerHighest,
                          color: over
                              ? Colors.red.shade600
                              : Colors.green.shade600,
                          minHeight: 6,
                        ),
                      ),
                      if (b.money!.rolloverAmount != 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Rollover: ${RulesAndBudgetsPage._currFmt.format(b.money!.rolloverAmount)}',
                            style: TextStyle(
                              fontSize: 11,
                              color: b.money!.rolloverAmount >= 0
                                  ? Colors.green.shade600
                                  : Colors.red.shade600,
                            ),
                          ),
                        ),
                    ],
                  ),
                  isThreeLine: true,
                  trailing:
                      Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () =>
                            showNodeEditor(context, existing: b)),
                    IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () =>
                            context.read<NodeCubit>().deleteNode(b.id)),
                  ]),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Add Budget'),
                  onPressed: () =>
                      showNodeEditor(context, enableMoney: true),
                )),
          ),
        ]);
      },
    );
  }
}
