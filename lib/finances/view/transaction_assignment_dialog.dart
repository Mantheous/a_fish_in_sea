import 'package:a_fish_in_sea/finances/bloc/expense_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/recurring_rules_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';
import 'package:a_fish_in_sea/finances/model/recurring_rule.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

/// Dialog for assigning a Plaid transaction to an expense.
///
/// Shows a list of unlinked expenses that the user can pick from.
/// Handles subdivision (transaction < expense) and over-budget
/// (transaction > expense) automatically.
class TransactionAssignmentDialog extends StatelessWidget {
  final Transaction transaction;

  const TransactionAssignmentDialog({super.key, required this.transaction});

  static final _currFmt = NumberFormat.currency(symbol: '\$');
  static final _dateFmt = DateFormat('M/d/yy');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BlocBuilder<ExpenseCubit, List<Expense>>(
      builder: (context, expenses) {
        // Filter to unlinked manual/concrete expenses only
        final available =
            expenses.where((e) => !e.isConcrete).toList();

        // Generate and add virtual projections from recurring rules
        final today = DateTime.now();
        final transactionDate = transaction.date;
        // Generate from the earlier of (transaction.date - 30 days) and today - 30 days
        final fromDate = transactionDate.isBefore(today)
            ? transactionDate.subtract(const Duration(days: 30))
            : today.subtract(const Duration(days: 30));
        final horizon = today.add(const Duration(days: 365));

        final existingRuleExpenseIds = expenses
            .where((e) => e.sourceRuleId != null)
            .map((e) => e.id)
            .toSet();

        final recurringRules = context.read<RecurringRulesCubit>().state;
        for (final RecurringRule rule in recurringRules) {
          // Filter: only show virtual projections with the same transaction sign (income vs expense)
          final isTransactionIncome = transaction.amount > 0;
          final isRuleIncome = rule.amount > 0;
          if (isTransactionIncome != isRuleIncome) continue;

          final projected = rule.generateExpenses(
            fromDate: fromDate,
            horizon: horizon,
          );

          for (final exp in projected) {
            if (!existingRuleExpenseIds.contains(exp.id)) {
              available.add(exp);
            }
          }
        }

        // Check for auto-categorization suggestion
        final suggestedId = context
            .read<TransactionsCubit>()
            .suggestExpenseForTransaction(transaction.name);

        // Sort: suggested match first, then by date proximity
        available.sort((a, b) {
          if (a.id == suggestedId) return -1;
          if (b.id == suggestedId) return 1;
          final diffA = (a.date.difference(transaction.date).inDays).abs();
          final diffB = (b.date.difference(transaction.date).inDays).abs();
          return diffA.compareTo(diffB);
        });

        return AlertDialog(
          title: const Text('Assign to Expense'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Transaction info
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: theme.colorScheme.surfaceContainerHigh,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(transaction.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            Text(_dateFmt.format(transaction.date),
                                style: theme.textTheme.bodySmall),
                          ],
                        ),
                      ),
                      Text(
                        _currFmt.format(transaction.amount),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: transaction.amount > 0
                              ? Colors.green.shade700
                              : Colors.red.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Available expenses
                if (available.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        'No unlinked expenses available.\nCreate an expense first.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  )
                else ...[
                  Text('Select an expense:',
                      style: theme.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: available.length,
                      itemBuilder: (context, index) {
                        final expense = available[index];
                        final isSuggested = expense.id == suggestedId;
                        final amountDiff =
                            (transaction.amount.abs() - expense.amount.abs());

                        return Card(
                          color: isSuggested
                              ? theme.colorScheme.primaryContainer
                                  .withValues(alpha: 0.3)
                              : null,
                          child: ListTile(
                            dense: true,
                            leading: isSuggested
                                ? Icon(Icons.auto_awesome,
                                    color: theme.colorScheme.primary,
                                    size: 20)
                                : null,
                            title: Row(
                              children: [
                                Expanded(
                                    child: Text(expense.name,
                                        overflow: TextOverflow.ellipsis)),
                                if (isSuggested)
                                  Chip(
                                    label: const Text('Suggested',
                                        style: TextStyle(fontSize: 10)),
                                    visualDensity: VisualDensity.compact,
                                    side: BorderSide.none,
                                    backgroundColor: theme
                                        .colorScheme.primaryContainer,
                                  ),
                              ],
                            ),
                            subtitle: Row(
                              children: [
                                Text(
                                    '${_currFmt.format(expense.amount)} · ${_dateFmt.format(expense.date)}'),
                                if (amountDiff.abs() > 0.01)
                                  Text(
                                    amountDiff > 0
                                        ? ' (over by ${_currFmt.format(amountDiff)})'
                                        : ' (under by ${_currFmt.format(amountDiff.abs())})',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: amountDiff > 0
                                          ? Colors.red.shade600
                                          : Colors.green.shade600,
                                    ),
                                  ),
                              ],
                            ),
                            onTap: () => _assign(context, expense),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }

  void _assign(BuildContext context, Expense expense) {
    final expenseCubit = context.read<ExpenseCubit>();
    final transactionsCubit = context.read<TransactionsCubit>();

    // If it's a virtual projection, create it in the expense cubit first
    if (expenseCubit.findById(expense.id) == null) {
      expenseCubit.addExpense(expense);
    }

    // Link the expense to this transaction
    expenseCubit.linkToTransaction(
      expenseId: expense.id,
      transactionId: transaction.id,
      transactionAmount: transaction.amount,
    );

    // Mark the transaction as assigned
    transactionsCubit.assignExpense(transaction.id, expense.id);

    Navigator.pop(context);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            'Assigned "${transaction.name}" to "${expense.name}"'),
      ),
    );
  }
}
