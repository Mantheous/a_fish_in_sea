import 'package:a_fish_in_sea/finances/bloc/expenses_cubit.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';
import 'package:a_fish_in_sea/finances/model/expense_catagory_and_tier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart'; // Helpful for formatting dates

class ModifyExpenseMenu extends StatefulWidget {
  final Expense? expense;
  const ModifyExpenseMenu({super.key, this.expense});

  @override
  State<ModifyExpenseMenu> createState() => _ModifyExpenseMenuState();
}

class _ModifyExpenseMenuState extends State<ModifyExpenseMenu> {
  late ExpenseCategory _selectedCategory;
  late DateTime _selectedDate;
  late ExpenseTimeTier _selectedTimeTier;

  late TextEditingController _nameController;
  late TextEditingController _amountController;

  @override
  void initState() {
    super.initState();
    if (widget.expense == null) {
      _nameController = TextEditingController();
      _amountController = TextEditingController();
      _selectedDate = DateTime.now();
      _selectedCategory = ExpenseCategory.unclasified;
      _selectedTimeTier = ExpenseTimeTier.month;
    } else {
      _nameController = TextEditingController(text: widget.expense!.name);
      _amountController = TextEditingController(
        text: widget.expense!.maxAmount.toString(),
      );
      _selectedDate = widget.expense!.dueDate ?? DateTime.now();
      _selectedCategory = widget.expense!.type;
      _selectedTimeTier = widget.expense!.timeTier;
    }
  }

  // 2. Method to show the date picker
  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000), // Earliest date allowed
      lastDate: DateTime(2101), // Latest date allowed
    );
    if (picked != null && picked != _selectedDate) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New Expense')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Expense Name'),
            ),
            TextField(
              controller: _amountController,
              decoration: const InputDecoration(labelText: 'Amount'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 10),

            // 3. Date Picker UI
            ListTile(
              title: Text(
                "Date: ${DateFormat('yyyy-MM-dd').format(_selectedDate)}",
              ),
              trailing: const Icon(Icons.calendar_today),
              onTap: () => _selectDate(context),
              contentPadding: EdgeInsets.zero,
            ),

            const SizedBox(height: 10),
            DropdownButton<ExpenseCategory>(
              isExpanded: true,
              hint: const Text('Select category'),
              value: _selectedCategory,
              items: ExpenseCategory.values.map((category) {
                return DropdownMenuItem(
                  value: category,
                  child: Text(category.name.toUpperCase()),
                );
              }).toList(),
              onChanged: (value) {
                // 4. Wrap in setState to update UI
                setState(() {
                  _selectedCategory = value!;
                });
              },
            ),
            DropdownButton<ExpenseTimeTier>(
              isExpanded: true,
              hint: const Text('Select time tier'),
              value: _selectedTimeTier,
              items: ExpenseTimeTier.values.map((tier) {
                return DropdownMenuItem(
                  value: tier,
                  child: Text(tier.name.toUpperCase()),
                );
              }).toList(),
              onChanged: (value) {
                // 4. Wrap in setState to update UI
                setState(() {
                  _selectedTimeTier = value!;
                });
              },
            ),
            const Spacer(), // Push the button to the bottom
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  // Ensure both fields are filled
                  if (_nameController.text.trim().isEmpty ||
                      _amountController.text.trim().isEmpty) {
                    // 2. Display the message
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Please fill in both the Name and Amount fields.',
                        ),
                        backgroundColor: Colors.redAccent,
                        behavior: SnackBarBehavior
                            .floating, // Optional: makes it hover
                      ),
                    );
                    return; // Stop execution here
                  }
                  // Make sure amount is a valid number
                  final parsedAmount = double.tryParse(_amountController.text);
                  if (parsedAmount == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Please enter a valid number for the amount.',
                        ),
                      ),
                    );
                    return;
                  }
                  // Add the new expense using the cubit
                  if (widget.expense == null) {
                    context.read<ExpensesCubit>().addExpense(
                      Expense(
                        name: _nameController.text,
                        maxAmount: parsedAmount,
                        dueDate: _selectedDate,
                        type: _selectedCategory,
                      ),
                    );
                  } else {
                    context.read<ExpensesCubit>().modifyExpense(
                      oldExpense: widget.expense!,
                      newExpense: Expense(
                        name: _nameController.text,
                        maxAmount: parsedAmount,
                        dueDate: _selectedDate,
                        type: _selectedCategory,
                      ),
                    );
                  }

                  Navigator.pop(context);
                },
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
