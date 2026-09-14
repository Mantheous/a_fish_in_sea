import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

/// Dialog for assigning a Plaid transaction to a money node.
///
/// Shows open (unpaid) money nodes — dated singles and generated
/// template instances — sorted by date proximity, with the
/// same-name suggestion first. Linking reports the node automatically
/// (exact / subdivide / over-cap, same policy as before).
class TransactionAssignmentDialog extends StatefulWidget {
  final Transaction transaction;

  const TransactionAssignmentDialog({super.key, required this.transaction});

  static final _currFmt = NumberFormat.currency(symbol: '\$');
  static final _dateFmt = DateFormat('M/d/yy');

  @override
  State<TransactionAssignmentDialog> createState() =>
      _TransactionAssignmentDialogState();
}

class _TransactionAssignmentDialogState
    extends State<TransactionAssignmentDialog> {
  bool _ensured = false;

  Transaction get transaction => widget.transaction;

  @override
  void initState() {
    super.initState();
    // Materialize template instances around the transaction date so
    // recurring projections are assignable (silent, convergent).
    // Post-frame: generation emits, which must not happen during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _ensured) return;
      _ensured = true;
      try {
        final nodeCubit = context.read<NodeCubit>();
        final fromDate =
            transaction.date.subtract(const Duration(days: 30));
        final horizon = DateTime.now().add(const Duration(days: 365));
        for (final template in nodeCubit.state) {
          if (template.isTemplate && template.money != null) {
            nodeCubit.generateInstances(
              templateId: template.id,
              from: fromDate,
              horizon: horizon,
            );
          }
        }
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BlocBuilder<NodeCubit, List<Node>>(
      builder: (context, nodes) {
        final isIncome = transaction.amount > 0;
        final available = nodes.where((n) {
          final m = n.money;
          if (m == null || n.isTemplate) return false;
          if (m.status == MoneyStatus.paid) return false;
          if (isIncome != (m.direction == MoneyDirection.income)) {
            return false;
          }
          return true;
        }).toList();

        // Same-name suggestion from node assignment history.
        final suggestedId = context
            .read<TransactionsCubit>()
            .suggestNodeForTransaction(transaction.name);

        DateTime? nodeDate(Node n) =>
            n.schedule?.due ?? n.schedule?.start ?? n.schedule?.end;

        // Sort: suggested match first, then by date proximity.
        available.sort((a, b) {
          if (a.id == suggestedId) return -1;
          if (b.id == suggestedId) return 1;
          final da = nodeDate(a);
          final db = nodeDate(b);
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          final diffA = (da.difference(transaction.date).inDays).abs();
          final diffB = (db.difference(transaction.date).inDays).abs();
          return diffA.compareTo(diffB);
        });

        return AlertDialog(
          title: const Text('Assign to Node'),
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
                            Text(TransactionAssignmentDialog._dateFmt.format(transaction.date),
                                style: theme.textTheme.bodySmall),
                          ],
                        ),
                      ),
                      Text(
                        TransactionAssignmentDialog._currFmt.format(transaction.amount),
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

                // Available nodes
                if (available.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        'No open money nodes available.\nCreate one first.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  )
                else ...[
                  Text('Select a node:',
                      style: theme.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: available.length,
                      itemBuilder: (context, index) {
                        final node = available[index];
                        final isSuggested = node.id == suggestedId;
                        final target =
                            node.money?.effectiveTarget ?? 0;
                        final amountDiff =
                            transaction.amount.abs() - target;

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
                                    child: Text(node.title,
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
                                    '${TransactionAssignmentDialog._currFmt.format(target)} · ${TransactionAssignmentDialog._dateFmt.format(nodeDate(node) ?? transaction.date)}'),
                                if (target > 0 && amountDiff.abs() > 0.01)
                                  Text(
                                    amountDiff > 0
                                        ? ' (over by ${TransactionAssignmentDialog._currFmt.format(amountDiff)})'
                                        : ' (under by ${TransactionAssignmentDialog._currFmt.format(amountDiff.abs())})',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: amountDiff > 0
                                          ? Colors.red.shade600
                                          : Colors.green.shade600,
                                    ),
                                  ),
                              ],
                            ),
                            onTap: () => _assign(context, node),
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

  void _assign(BuildContext context, Node node) {
    final nodeCubit = context.read<NodeCubit>();
    final transactionsCubit = context.read<TransactionsCubit>();

    // Link the node to this transaction (exact / subdivide / over-cap).
    nodeCubit.linkTransaction(
      nodeId: node.id,
      transactionId: transaction.id,
      transactionAmount: transaction.amount,
    );

    // Mark the transaction as assigned to the node.
    transactionsCubit.assignNode(transaction.id, node.id);

    Navigator.pop(context);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text('Assigned "${transaction.name}" to "${node.title}"'),
      ),
    );
  }
}
