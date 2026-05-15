import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/view/transaction_expense_select_bottom_sheet.dart';
import 'package:a_fish_in_sea/navigation/view/navigation_bar.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class TransactionHistoryPage extends StatelessWidget {
  final ThemeData theme;
  const TransactionHistoryPage({super.key, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Transactions"),
        actions: [
          FloatingActionButton(
            child: const Icon(Icons.add),
            onPressed: () {
              context.read<TransactionsCubit>().pickNewCSV();
            },
          ),
        ],
      ),
      bottomNavigationBar: NavBar(),
      body: Center(
        child: AspectRatio(
          aspectRatio: 0.5,
          child: BlocBuilder<TransactionsCubit, List<Transaction>>(
            builder: (context, state) {
              final transactions = context
                  .read<TransactionsCubit>()
                  .loadedTransactions;
              if (transactions.isEmpty) {
                return const Center(child: Text('No transactions available'));
              } else {
                return SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: DataTable(
                    horizontalMargin: 5,
                    columnSpacing: 10,
                    columns: [
                      const DataColumn(label: Text('Type')),
                      const DataColumn(label: Text('Date')),
                      const DataColumn(label: Text('Description')),
                      const DataColumn(label: Text('Amount')),
                    ],
                    rows: transactions.map((transaction) {
                      return DataRow(
                        cells: [
                          DataCell(
                            FloatingActionButton(
                              onPressed: () {
                                showModalBottomSheet(
                                  context: context,
                                  isScrollControlled: true,
                                  builder: (_) =>
                                      TransactionExpenseSelectBottomSheet(
                                        transaction: transaction,
                                      ),
                                );
                              },
                              child: Icon(
                                transaction.assignedExpense == null
                                    ? Icons.question_mark
                                    : Icons.done_all_outlined,
                              ),
                            ),
                          ),
                          DataCell(
                            Text(
                              Transaction.formatter.format(transaction.date),
                            ),
                          ),
                          DataCell(Text(transaction.description)),
                          DataCell(
                            Text('\$${transaction.amount.toStringAsFixed(2)}'),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                );
              }
            },
          ),
        ),
      ),
    );
  }
}
