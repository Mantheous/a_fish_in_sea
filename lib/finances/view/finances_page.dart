import 'package:a_fish_in_sea/finances/bloc/expenses_cubit.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';
import 'package:a_fish_in_sea/navigation/view/navigation_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class FinancesPage extends StatelessWidget {
  final ThemeData theme;
  const FinancesPage({super.key, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: NavBar(),
      body: Column(children: [
      BlocBuilder<ExpensesCubit, List<Expense>>(builder: (context, state) {
        return Column(children: context.read<ExpensesCubit>().state.map((x)=> 
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.all(8.0),
              padding: const EdgeInsets.all(8.0),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: Text(
                  x.maxAmount.toString(),
                  style: theme.textTheme.bodyLarge!.copyWith(color: theme.colorScheme.onPrimary),
                ),
              ),
            )).toList(),
            );
      }),
      Align(
          alignment: Alignment.bottomRight,
          child: Container(
            margin: const EdgeInsets.all(8.0),
            padding: const EdgeInsets.all(8.0),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(8.0)
            ),
            child: FloatingActionButton(onPressed: () => context.read<ExpensesCubit>().addExpense(Expense(maxAmount: 100))),
          )
        ),
     ]));
  }
}