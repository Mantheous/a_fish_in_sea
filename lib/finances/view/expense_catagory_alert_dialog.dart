import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/model/expense_catagory_and_tier.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class ExpenseCatagoryAlertDialog extends StatelessWidget {
  final Transaction transaction;
  const ExpenseCatagoryAlertDialog({super.key, required this.transaction});

  @override
  Widget build(BuildContext context) {
    return StatefulBuilder(
      builder: (context, setState) {
        return AlertDialog(
          title: const Text('Select expense type'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: ExpenseCatagory.values.map((type) {
              return RadioListTile<ExpenseCatagory>(
                title: Text(type.name.toUpperCase()),
                value: type,
                groupValue: transaction.type,
                onChanged: (value) {
                  setState(
                    () => context
                        .read<TransactionsCubit>()
                        .changeTransactionExpenseType(transaction, value!),
                  );
                  Navigator.pop(context);
                },
              );
            }).toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Accept'),
            ),
          ],
        );
      },
    );
  }
}
