import 'package:a_fish_in_sea/finances/bloc/expense_cubit.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

/// Dialog for viewing and editing an individual expense with
/// prefab-style controls (override, revert, subdivide, merge).
class ExpenseDetailDialog extends StatefulWidget {
  final Expense expense;

  const ExpenseDetailDialog({super.key, required this.expense});

  @override
  State<ExpenseDetailDialog> createState() => _ExpenseDetailDialogState();
}

class _ExpenseDetailDialogState extends State<ExpenseDetailDialog> {
  late TextEditingController _nameCtrl;
  late TextEditingController _amountCtrl;
  late DateTime _date;
  String? _category;

  static final _currFmt = NumberFormat.currency(symbol: '\$');

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.expense.name);
    _amountCtrl = TextEditingController(
        text: widget.expense.amount.abs().toStringAsFixed(2));
    _date = widget.expense.date;
    _category = widget.expense.category;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expense = widget.expense;
    final hasParent = expense.parentExpenseId != null;

    return AlertDialog(
      title: Row(
        children: [
          Text(expense.isConcrete ? 'Concrete Expense' : 'Edit Expense'),
          const Spacer(),
          if (expense.isConcrete)
            Chip(
              label: const Text('Linked', style: TextStyle(fontSize: 11)),
              backgroundColor: Colors.green.withValues(alpha: 0.15),
              side: BorderSide.none,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Name
            _buildOverridableField(
              fieldName: 'name',
              label: 'Name',
              controller: _nameCtrl,
              isOverridden: expense.overriddenFields.contains('name'),
              hasParent: hasParent,
              isConcrete: expense.isConcrete,
            ),
            const SizedBox(height: 12),

            // Amount
            _buildOverridableField(
              fieldName: 'amount',
              label: 'Amount',
              controller: _amountCtrl,
              isOverridden: expense.overriddenFields.contains('amount'),
              hasParent: hasParent,
              isConcrete: expense.isConcrete,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              prefix: '\$ ',
            ),
            const SizedBox(height: 12),

            // Date
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Date: ${DateFormat('yyyy-MM-dd').format(_date)}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasParent && expense.overriddenFields.contains('date'))
                    _revertIcon('date'),
                  const Icon(Icons.calendar_today),
                ],
              ),
              onTap: expense.isConcrete
                  ? null
                  : () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _date,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) setState(() => _date = picked);
                    },
            ),

            // Category
            TextField(
              decoration: const InputDecoration(labelText: 'Category'),
              controller: TextEditingController(text: _category ?? ''),
              onChanged: (v) => _category = v.isEmpty ? null : v,
              enabled: !expense.isConcrete,
            ),
            const SizedBox(height: 16),

            // Status info
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: theme.colorScheme.surfaceContainerHigh,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _infoRow('Status', expense.status.name.toUpperCase()),
                  if (expense.sourceRuleId != null)
                    _infoRow('From rule', expense.sourceRuleId!),
                  if (expense.linkedTransactionId != null)
                    _infoRow('Linked to', expense.linkedTransactionId!),
                  if (expense.overriddenFields.isNotEmpty)
                    _infoRow(
                      'Overrides',
                      expense.overriddenFields.join(', '),
                    ),
                ],
              ),
            ),

            // Subdivision
            if (!expense.isConcrete) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              Text('Actions', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _showSubdivideDialog(context),
                    icon: const Icon(Icons.call_split, size: 18),
                    label: const Text('Subdivide'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      context.read<ExpenseCubit>().deleteExpense(expense.id);
                      Navigator.pop(context);
                    },
                    icon: Icon(Icons.delete_outline,
                        size: 18, color: theme.colorScheme.error),
                    label: Text('Delete',
                        style: TextStyle(color: theme.colorScheme.error)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (!expense.isConcrete)
          FilledButton(
            onPressed: _save,
            child: const Text('Save'),
          ),
      ],
    );
  }

  Widget _buildOverridableField({
    required String fieldName,
    required String label,
    required TextEditingController controller,
    required bool isOverridden,
    required bool hasParent,
    required bool isConcrete,
    TextInputType? keyboardType,
    String? prefix,
  }) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            keyboardType: keyboardType,
            enabled: !isConcrete,
            decoration: InputDecoration(
              labelText: label,
              prefixText: prefix,
              suffixIcon: isOverridden && hasParent
                  ? Icon(Icons.edit, size: 16, color: Colors.orange.shade600)
                  : null,
            ),
          ),
        ),
        if (hasParent && isOverridden && !isConcrete)
          _revertIcon(fieldName),
      ],
    );
  }

  Widget _revertIcon(String fieldName) {
    return IconButton(
      icon: Icon(Icons.undo, size: 18, color: Colors.blue.shade600),
      tooltip: 'Revert to parent value',
      onPressed: () {
        context.read<ExpenseCubit>().revertExpenseField(
              widget.expense.id, fieldName);
        Navigator.pop(context);
      },
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text('$label: ',
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 12)),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  void _showSubdivideDialog(BuildContext context) {
    final splitCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Subdivide Expense'),
        content: TextField(
          controller: splitCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Split amount',
            prefixText: '\$ ',
            helperText:
                'Current: ${_currFmt.format(widget.expense.amount.abs())}',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final splitAmount = double.tryParse(splitCtrl.text);
              if (splitAmount != null && splitAmount > 0) {
                context
                    .read<ExpenseCubit>()
                    .subdivideExpense(widget.expense.id, splitAmount);
                Navigator.pop(ctx);
                Navigator.pop(context);
              }
            },
            child: const Text('Split'),
          ),
        ],
      ),
    );
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    final parsed = double.tryParse(_amountCtrl.text.trim());
    if (name.isEmpty || parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name and valid amount required')),
      );
      return;
    }

    final cubit = context.read<ExpenseCubit>();
    var updated = widget.expense;

    // Track overrides
    if (name != widget.expense.name) {
      updated = updated.overrideField('name', name);
    }
    final newAmount =
        widget.expense.amount < 0 ? -parsed.abs() : parsed.abs();
    if (newAmount != widget.expense.amount) {
      updated = updated.overrideField('amount', newAmount);
    }
    if (_date != widget.expense.date) {
      updated = updated.overrideField('date', _date);
    }
    if (_category != widget.expense.category) {
      updated = updated.copyWith(
        category: _category,
        overriddenFields: {...updated.overriddenFields, 'category'},
      );
    }

    cubit.updateExpense(updated);
    Navigator.pop(context);
  }
}
