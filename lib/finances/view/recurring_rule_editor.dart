import 'package:a_fish_in_sea/finances/bloc/recurring_rules_cubit.dart';
import 'package:a_fish_in_sea/finances/model/recurring_rule.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

class RecurringRuleEditor extends StatefulWidget {
  final RecurringRule? existingRule;
  const RecurringRuleEditor({super.key, this.existingRule});

  @override
  State<RecurringRuleEditor> createState() => _RecurringRuleEditorState();
}

class _RecurringRuleEditorState extends State<RecurringRuleEditor> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _amountCtrl;
  late final TextEditingController _customDaysCtrl;
  late TimeScale _frequency;
  late DateTime _startDate;
  DateTime? _endDate;
  bool _isExpense = true;
  String? _category;

  @override
  void initState() {
    super.initState();
    final r = widget.existingRule;
    _nameCtrl = TextEditingController(text: r?.name ?? '');
    _amountCtrl = TextEditingController(text: r != null ? r.amount.abs().toString() : '');
    _customDaysCtrl = TextEditingController(text: r?.customPeriodDays?.toString() ?? '90');
    _frequency = r?.frequency ?? TimeScale.monthly;
    _startDate = r?.startDate ?? DateTime.now();
    _endDate = r?.endDate;
    _isExpense = r != null ? r.amount < 0 : true;
    _category = r?.category;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _amountCtrl.dispose();
    _customDaysCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.existingRule == null ? 'New Recurring Rule' : 'Edit Rule')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: 8),
          TextField(controller: _amountCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount', prefixText: '\$ ')),
          const SizedBox(height: 12),
          Row(children: [
            ChoiceChip(label: const Text('Expense'), selected: _isExpense, onSelected: (_) => setState(() => _isExpense = true)),
            const SizedBox(width: 8),
            ChoiceChip(label: const Text('Income'), selected: !_isExpense, onSelected: (_) => setState(() => _isExpense = false)),
          ]),
          const SizedBox(height: 12),
          DropdownButtonFormField<TimeScale>(
            initialValue: _frequency,
            decoration: const InputDecoration(labelText: 'Frequency'),
            items: TimeScale.values.map((s) => DropdownMenuItem(value: s, child: Text(s.displayName))).toList(),
            onChanged: (v) => setState(() => _frequency = v!),
          ),
          if (_frequency == TimeScale.custom) ...[
            const SizedBox(height: 8),
            TextField(controller: _customDaysCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Custom period (days)', helperText: 'e.g. 120 for semesters')),
          ],
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Start: ${DateFormat('yyyy-MM-dd').format(_startDate)}'),
            trailing: const Icon(Icons.calendar_today),
            onTap: () async {
              final d = await showDatePicker(context: context, initialDate: _startDate, firstDate: DateTime(2000), lastDate: DateTime(2100));
              if (d != null) setState(() => _startDate = d);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_endDate != null ? 'End: ${DateFormat('yyyy-MM-dd').format(_endDate!)}' : 'End: Indefinite'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (_endDate != null) IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() => _endDate = null)),
              const Icon(Icons.calendar_today),
            ]),
            onTap: () async {
              final d = await showDatePicker(context: context, initialDate: _endDate ?? _startDate.add(const Duration(days: 365)), firstDate: _startDate, lastDate: DateTime(2100));
              if (d != null) setState(() => _endDate = d);
            },
          ),
          TextField(
            decoration: const InputDecoration(labelText: 'Category (optional)'),
            controller: TextEditingController(text: _category),
            onChanged: (v) => _category = v.isEmpty ? null : v,
          ),
          const SizedBox(height: 24),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: _save, child: const Text('Save'))),
        ]),
      ),
    );
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    final parsed = double.tryParse(_amountCtrl.text.trim());
    if (name.isEmpty || parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name and valid amount required')));
      return;
    }
    final amount = _isExpense ? -parsed.abs() : parsed.abs();
    final id = widget.existingRule?.id ?? 'rule_${DateTime.now().millisecondsSinceEpoch}';
    final rule = RecurringRule(
      id: id, name: name, amount: amount, frequency: _frequency,
      customPeriodDays: _frequency == TimeScale.custom ? int.tryParse(_customDaysCtrl.text) : null,
      startDate: _startDate, endDate: _endDate, category: _category,
    );
    final cubit = context.read<RecurringRulesCubit>();
    if (widget.existingRule == null) {
      cubit.addRule(rule);
    } else {
      cubit.updateRule(rule);
    }
    Navigator.pop(context);
  }
}
