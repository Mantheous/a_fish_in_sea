import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/expenses_cubit.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class TransactionExpenseSelectBottomSheet extends StatefulWidget {
  final Transaction transaction;
  const TransactionExpenseSelectBottomSheet({
    super.key,
    required this.transaction,
  });

  @override
  State<TransactionExpenseSelectBottomSheet> createState() =>
      _TransactionExpenseSelectBottomSheetState();
}

class _TransactionExpenseSelectBottomSheetState
    extends State<TransactionExpenseSelectBottomSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _query = _searchController.text;
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.7,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search expenses',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            Expanded(
              child: BlocBuilder<ExpensesCubit, List<Expense>>(
                builder: (context, expenses) {
                  final filtered = expenses
                      .where(
                        (e) =>
                            e.name.toLowerCase().contains(_query.toLowerCase()),
                      )
                      .toList();

                  if (filtered.isEmpty) {
                    return const Center(child: Text('No expenses found'));
                  }

                  return ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final expense = filtered[index];
                      return ListTile(
                        title: Text(expense.name),
                        subtitle: Text(expense.typeCapitalized),
                        onTap: () {
                          context.read<TransactionsCubit>().setExpense(
                            widget.transaction,
                            expense,
                          );
                          Navigator.of(context).pop();
                        },
                      );
                    },
                  );
                },
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}
