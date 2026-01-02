import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/view/expense_catagory_alert_dialog.dart';
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
      bottomNavigationBar: NavBar(),
      body: Center(
        child: AspectRatio(
          aspectRatio: 0.5,
          child: BlocBuilder<TransactionsCubit, List<Transaction>>(
            builder: (context, transactions) {
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
                                showDialog(
                                  context: context,
                                  builder: (_) => ExpenseCatagoryAlertDialog(
                                    transaction: transaction,
                                  ),
                                );
                              },
                              child: Text(transaction.type.name.toUpperCase()),
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
