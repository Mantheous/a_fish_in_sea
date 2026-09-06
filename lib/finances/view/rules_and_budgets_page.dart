import 'package:a_fish_in_sea/finances/bloc/budget_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/expense_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/recurring_rules_cubit.dart';
import 'package:a_fish_in_sea/finances/model/budget.dart';
import 'package:a_fish_in_sea/finances/model/recurring_rule.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/view/budget_editor.dart';
import 'package:a_fish_in_sea/finances/view/recurring_rule_editor.dart';
import 'package:a_fish_in_sea/navigation/view/navigation_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

/// Management page with two tabs: Recurring Rules and Budget Templates.
class RulesAndBudgetsPage extends StatelessWidget {
  const RulesAndBudgetsPage({super.key, this.showBottomNav = true});

  final bool showBottomNav;

  static final _currFmt = NumberFormat.currency(symbol: '\$');

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        bottomNavigationBar: showBottomNav ? const NavBar() : null,
        appBar: AppBar(
          title: const Text('Rules & Budgets'),
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.repeat), text: 'Recurring'),
            Tab(icon: Icon(Icons.pie_chart_outline), text: 'Budgets'),
          ]),
        ),
        body: const TabBarView(children: [
          _RecurringRulesTab(),
          _BudgetsTab(),
        ]),
      ),
    );
  }
}

class _RecurringRulesTab extends StatelessWidget {
  const _RecurringRulesTab();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<RecurringRulesCubit, List<RecurringRule>>(
      builder: (context, rules) {
        return Column(children: [
          Expanded(
            child: rules.isEmpty
                ? const Center(child: Text('No recurring rules yet.\nTap + to add one.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
                : ListView.separated(
                    itemCount: rules.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final r = rules[i];
                      return ListTile(
                        title: Text(r.name),
                        subtitle: Text('${RulesAndBudgetsPage._currFmt.format(r.amount)} · ${r.frequency.displayName}${r.category != null ? ' · ${r.category}' : ''}'),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () {
                            Navigator.push(context, MaterialPageRoute(builder: (_) => RecurringRuleEditor(existingRule: r)));
                          }),
                          IconButton(icon: const Icon(Icons.delete_outline), onPressed: () {
                            context.read<RecurringRulesCubit>().deleteRule(r.id);
                          }),
                        ]),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(width: double.infinity, child: FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add Recurring Rule'),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RecurringRuleEditor())),
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

    return BlocBuilder<BudgetCubit, List<Budget>>(
      builder: (context, budgets) {
        return Column(children: [
          Expanded(
            child: budgets.isEmpty
                ? const Center(child: Text('No budgets yet.\nTap + to add one.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
                : BlocBuilder<ExpenseCubit, List<dynamic>>(
                    builder: (context, expenses) {
                      return ListView.separated(
                        itemCount: budgets.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final b = budgets[i];
                          final status = context.read<BudgetCubit>().getBudgetStatus(b.id, context.read<ExpenseCubit>().state);
                          final progress = status.goalAmount > 0
                              ? (status.spentAmount / status.goalAmount).clamp(0.0, 2.0)
                              : 0.0;

                          return ListTile(
                            title: Text(b.name),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${RulesAndBudgetsPage._currFmt.format(status.spentAmount)} / ${RulesAndBudgetsPage._currFmt.format(b.goalAmount)} · ${b.period.displayName}',
                                ),
                                const SizedBox(height: 4),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: progress,
                                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                                    color: status.isOverBudget
                                        ? Colors.red.shade600
                                        : Colors.green.shade600,
                                    minHeight: 6,
                                  ),
                                ),
                                if (b.rolloverAmount != 0)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      'Rollover: ${RulesAndBudgetsPage._currFmt.format(b.rolloverAmount)}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: b.rolloverAmount >= 0 ? Colors.green.shade600 : Colors.red.shade600,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            isThreeLine: true,
                            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () {
                                Navigator.push(context, MaterialPageRoute(builder: (_) => BudgetEditor(existingBudget: b)));
                              }),
                              IconButton(icon: const Icon(Icons.delete_outline), onPressed: () {
                                context.read<BudgetCubit>().deleteBudget(b.id);
                              }),
                            ]),
                          );
                        },
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(width: double.infinity, child: FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add Budget'),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BudgetEditor())),
            )),
          ),
        ]);
      },
    );
  }
}
