import 'package:a_fish_in_sea/finances/model/expense.dart';
import 'package:a_fish_in_sea/finances/view/modify_expense_menu.dart';
import 'package:flutter/material.dart';

class ExpenseCard extends StatelessWidget {
  final Expense expense;
  const ExpenseCard({super.key, required this.expense});

  //TODO: This is filler UI. Get the functionality in the transaction/expense relationship working first

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        // clipBehavior is necessary because, without it, the InkWell's animation
        // will extend beyond the rounded edges of the [Card] (see https://github.com/flutter/flutter/issues/109776)
        // This comes with a small performance cost, and you should not set [clipBehavior]
        // unless you need it.
        clipBehavior: Clip.hardEdge,
        child: InkWell(
          splashColor: Colors.blue.withAlpha(30),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ModifyExpenseMenu(expense: expense),
              ),
            );
          },
          child: Row(
            children: [
              Padding(
                padding: EdgeInsets.all(20.0),
                child: Column(
                  children: [
                    Text(expense.name, style: const TextStyle(fontSize: 20)),
                    Text(expense.typeCapitalized),
                    if (expense.dueDate != null)
                      Row(
                        children: [
                          Text(
                            'Due: ${expense.dueDate!.month}/${expense.dueDate!.day}/${expense.dueDate!.year}',
                          ),
                          Text(expense.timeTier.name),
                        ],
                      ),
                  ],
                ),
              ),
              Spacer(),
              Padding(
                padding: EdgeInsets.all(20.0),
                child: Text(
                  '${expense.current.toStringAsFixed(2)} / ${expense.maxAmount.toStringAsFixed(2)}',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
