import 'package:a_fish_in_sea/finances/bloc/budget_cubit.dart';
import 'package:a_fish_in_sea/finances/model/budget.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

/// Editor for creating and editing [Budget] goals.
class BudgetEditor extends StatefulWidget {
  final Budget? existingBudget;
  const BudgetEditor({super.key, this.existingBudget});

  @override
  State<BudgetEditor> createState() => _BudgetEditorState();
}

class _BudgetEditorState extends State<BudgetEditor> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _amountCtrl;
  late final TextEditingController _categoryCtrl;
  late final TextEditingController _customDaysCtrl;
  late TimeScale _period;
  late DateTime _startDate;
  DateTime? _endDate;
  late bool _isRecurring;
  late bool _autoRollover;

  @override
  void initState() {
    super.initState();
    final b = widget.existingBudget;
    _nameCtrl = TextEditingController(text: b?.name ?? '');
    _amountCtrl = TextEditingController(
        text: b != null ? b.goalAmount.toStringAsFixed(2) : '');
    _categoryCtrl = TextEditingController(text: b?.category ?? '');
    _customDaysCtrl = TextEditingController(
        text: b?.customPeriodDays?.toString() ?? '90');
    _period = b?.period ?? TimeScale.monthly;
    _startDate = b?.startDate ?? DateTime.now();
    _endDate = b?.endDate;
    _isRecurring = b?.isRecurring ?? true;
    _autoRollover = b?.autoRollover ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _amountCtrl.dispose();
    _categoryCtrl.dispose();
    _customDaysCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existingBudget == null
            ? 'New Budget'
            : 'Edit Budget'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _categoryCtrl,
              decoration: const InputDecoration(labelText: 'Category'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Goal Amount',
                prefixText: '\$ ',
                helperText: 'Target spending per period',
              ),
            ),
            const SizedBox(height: 16),

            // Period selector
            DropdownButtonFormField<TimeScale>(
              initialValue: _period,
              decoration: const InputDecoration(labelText: 'Period'),
              items: TimeScale.values
                  .map((s) => DropdownMenuItem(
                        value: s,
                        child: Text(s.displayName),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _period = v!),
            ),
            if (_period == TimeScale.custom) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _customDaysCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Custom period (days)',
                  helperText: 'e.g. 120 for semesters',
                ),
              ),
            ],
            const SizedBox(height: 16),

            // Dates
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                  'Start: ${DateFormat('yyyy-MM-dd').format(_startDate)}'),
              trailing: const Icon(Icons.calendar_today),
              onTap: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: _startDate,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (d != null) setState(() => _startDate = d);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_endDate != null
                  ? 'End: ${DateFormat('yyyy-MM-dd').format(_endDate!)}'
                  : 'End: Indefinite'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_endDate != null)
                    IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() => _endDate = null),
                    ),
                  const Icon(Icons.calendar_today),
                ],
              ),
              onTap: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: _endDate ??
                      _startDate.add(const Duration(days: 365)),
                  firstDate: _startDate,
                  lastDate: DateTime(2100),
                );
                if (d != null) setState(() => _endDate = d);
              },
            ),
            const SizedBox(height: 16),

            // Toggles
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Recurring'),
              subtitle: const Text('Budget repeats each period'),
              value: _isRecurring,
              onChanged: (v) => setState(() => _isRecurring = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto Rollover'),
              subtitle:
                  const Text('Carry surplus/deficit to the next period'),
              value: _autoRollover,
              onChanged: _isRecurring
                  ? (v) => setState(() => _autoRollover = v)
                  : null,
            ),

            // Rollover info (if editing an existing budget)
            if (widget.existingBudget != null &&
                widget.existingBudget!.rolloverAmount != 0)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHigh,
                  ),
                  child: Row(
                    children: [
                      const Text('Rollover: ',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                        '\$${widget.existingBudget!.rolloverAmount.toStringAsFixed(2)}',
                        style: TextStyle(
                          color:
                              widget.existingBudget!.rolloverAmount >= 0
                                  ? Colors.green.shade700
                                  : Colors.red.shade700,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _save,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    final category = _categoryCtrl.text.trim();
    final parsed = double.tryParse(_amountCtrl.text.trim());

    if (name.isEmpty || category.isEmpty || parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Name, category, and valid amount required')),
      );
      return;
    }

    final id = widget.existingBudget?.id ??
        'budget_${DateTime.now().millisecondsSinceEpoch}';

    final budget = Budget(
      id: id,
      name: name,
      category: category,
      goalAmount: parsed,
      period: _period,
      customPeriodDays:
          _period == TimeScale.custom ? int.tryParse(_customDaysCtrl.text) : null,
      startDate: _startDate,
      endDate: _endDate,
      isRecurring: _isRecurring,
      autoRollover: _autoRollover,
      rolloverAmount: widget.existingBudget?.rolloverAmount ?? 0.0,
    );

    final cubit = context.read<BudgetCubit>();
    if (widget.existingBudget == null) {
      cubit.addBudget(budget);
    } else {
      cubit.updateBudget(budget);
    }
    Navigator.pop(context);
  }
}
