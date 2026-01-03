import 'package:a_fish_in_sea/finances/bloc/expenses_cubit.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';
import 'package:a_fish_in_sea/finances/view/expense_card.dart';
import 'package:a_fish_in_sea/navigation/view/navigation_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

//I want two different view modes. One for viewing expenses as cards, another for viewing them as a table

class FinancesPage extends StatelessWidget {
  final ThemeData theme;
  const FinancesPage({super.key, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: NavBar(),
      body: Column(
        children: [
          BlocBuilder<ExpensesCubit, List<Expense>>(
            builder: (context, state) {
              return Column(
                children: context
                    .read<ExpensesCubit>()
                    .state
                    .map((x) => ExpenseCard(expense: x))
                    .toList(),
              );
            },
          ),
          Align(
            alignment: Alignment.bottomRight,
            child: Container(
              margin: const EdgeInsets.all(8.0),
              padding: const EdgeInsets.all(8.0),
              child: FloatingActionButton(
                child: const Icon(Icons.add),
                onPressed: () => context.read<ExpensesCubit>().addExpense(
                  Expense(name: 'New Expense', maxAmount: 100.0),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
