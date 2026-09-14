import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_progress.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/task_assignee.dart';
import 'package:a_fish_in_sea/planner/view/people_field.dart';

Future<void> showNodeEditor(
  BuildContext context, {
  Node? existing,
  bool enableMoney = false,
  bool enableRecurrence = false,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => _NodeEditorDialog(
      existing: existing,
      enableMoney: enableMoney,
      enableRecurrence: enableRecurrence,
    ),
  );
}

class _NodeEditorDialog extends StatefulWidget {
  final Node? existing;
  final bool enableMoney;
  final bool enableRecurrence;

  const _NodeEditorDialog(
      {this.existing, this.enableMoney = false, this.enableRecurrence = false});

  @override
  State<_NodeEditorDialog> createState() => _NodeEditorDialogState();
}

class _NodeEditorDialogState extends State<_NodeEditorDialog> {
  late final TextEditingController _title;
  late final TextEditingController _notes;
  late List<String> _parents;

  DateTime? _due;
  DateTime? _blockStart;
  DateTime? _blockEnd;
  bool _allDay = false;
  bool _dateFixed = false;

  bool _hasMoney = false;
  late final TextEditingController _amount;
  MoneyDirection _direction = MoneyDirection.spend;
  TimeScale? _period;
  late final TextEditingController _customDaysCtrl;
  bool _moneyRecurring = false;
  bool _autoRollover = false;
  bool _moneyFixed = false;

  bool _hasEffort = false;
  late final TextEditingController _minutes;
  bool _effortFixed = false;

  bool _hasRecurrence = false;
  TimeScale _frequency = TimeScale.daily;
  DateTime? _recurEnd;

  NodeRuleKind _ruleKind = NodeRuleKind.none;
  late final TextEditingController _horizon;
  late final TextEditingController _minBalance;

  late List<TaskAssignee> _people;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: e?.title ?? '');
    _notes = TextEditingController(text: e?.notes ?? '');
    _parents = List.of(e?.parentIds ?? const []);
    _due = e?.schedule?.due;
    _blockStart = e?.schedule?.start;
    _blockEnd = e?.schedule?.end;
    _allDay = e?.schedule?.allDay ?? false;
    _dateFixed = e?.schedule?.isFixed ?? false;
    _hasMoney = e?.money != null || widget.enableMoney;
    _amount = TextEditingController(
        text: e?.money != null
            ? e!.money!.targetAmount.toStringAsFixed(2)
            : '');
    _direction = e?.money?.direction ?? MoneyDirection.spend;
    _period = e?.money?.period;
    _customDaysCtrl = TextEditingController(
        text: e?.money?.customPeriodDays?.toString() ?? '90');
    _moneyRecurring = e?.money?.isRecurring ?? false;
    _autoRollover = e?.money?.autoRollover ?? false;
    _moneyFixed = e?.money?.isFixed ?? false;
    _hasEffort = e?.effort != null;
    _minutes = TextEditingController(
        text: e?.effort != null ? e!.effort!.targetMinutes.toString() : '');
    _effortFixed = e?.effort?.isFixed ?? false;
    _hasRecurrence = e?.recurrence != null || widget.enableRecurrence;
    _frequency = e?.recurrence?.frequency ?? TimeScale.daily;
    _recurEnd = e?.recurrence?.endDate;
    _ruleKind = e?.rule?.kind ?? NodeRuleKind.none;
    _horizon = TextEditingController(
        text: (e?.rule?.horizonDays ?? 3).toString());
    _minBalance = TextEditingController(
        text: (e?.rule?.minBalance ?? 0).toStringAsFixed(2));
    _people = List.of(e?.assignees ?? const []);
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _amount.dispose();
    _customDaysCtrl.dispose();
    _minutes.dispose();
    _horizon.dispose();
    _minBalance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.existing;
    return AlertDialog(
      title: Text(e == null ? 'New node' : 'Edit node'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _title,
              autofocus: e == null,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              decoration: const InputDecoration(
                labelText: 'Notes',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            _ParentsField(
              selected: _parents,
              excludeId: e?.id,
              onChanged: (next) => setState(() => _parents = next),
            ),
            const SizedBox(height: 12),
            PeopleField(
              selected: _people,
              onChanged: (next) => setState(() => _people = next),
            ),
            const SizedBox(height: 16),
            _sectionTitle(context, 'Schedule'),
            _DateRow(
              label: _due == null
                  ? 'No due date'
                  : 'Due ${MaterialLocalizations.of(context).formatFullDate(_due!)}${_dateFixed ? ' · fixed' : ''}',
              onPick: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _due ?? DateTime.now(),
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) setState(() => _due = picked);
              },
              onClear:
                  _due == null ? null : () => setState(() => _due = null),
            ),
            _BlockField(
              start: _blockStart,
              end: _blockEnd,
              allDay: _allDay,
              onChanged: (start, end, allDay) => setState(() {
                _blockStart = start;
                _blockEnd = end;
                _allDay = allDay;
              }),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Fixed date'),
              subtitle: const Text('Commitment; estimates stay flexible'),
              value: _dateFixed,
              onChanged: (v) => setState(() => _dateFixed = v),
            ),
            const SizedBox(height: 8),
            _sectionTitle(context, 'Money'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Tracks money'),
              value: _hasMoney,
              onChanged: (v) => setState(() => _hasMoney = v),
            ),
            if (_hasMoney) ...[
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Target amount',
                  prefixText: '\$ ',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<MoneyDirection>(
                initialValue: _direction,
                decoration: const InputDecoration(labelText: 'Direction'),
                items: const [
                  DropdownMenuItem(
                      value: MoneyDirection.spend,
                      child: Text('Spend (cap)')),
                  DropdownMenuItem(
                      value: MoneyDirection.income,
                      child: Text('Income')),
                  DropdownMenuItem(
                      value: MoneyDirection.save,
                      child: Text('Save toward')),
                ],
                onChanged: (v) =>
                    setState(() => _direction = v ?? _direction),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<TimeScale?>(
                initialValue: _period,
                decoration:
                    const InputDecoration(labelText: 'Period (optional)'),
                items: [
                  const DropdownMenuItem(
                      value: null, child: Text('One-time')),
                  for (final s in TimeScale.values)
                    DropdownMenuItem(value: s, child: Text(s.displayName)),
                ],
                onChanged: (v) => setState(() => _period = v),
              ),
              if (_period == TimeScale.custom) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _customDaysCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Custom period (days)'),
                ),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Recurring'),
                value: _moneyRecurring,
                onChanged: (v) => setState(() => _moneyRecurring = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Auto rollover'),
                value: _autoRollover,
                onChanged: _moneyRecurring
                    ? (v) => setState(() => _autoRollover = v)
                    : null,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Fixed amount'),
                value: _moneyFixed,
                onChanged: (v) => setState(() => _moneyFixed = v),
              ),
              if (e?.money != null &&
                  e!.money!.linkedTransactionIds.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Reported by ${e.money!.linkedTransactionIds.length} '
                    'transaction(s) · ${e.money!.status.name}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
            const SizedBox(height: 8),
            _sectionTitle(context, 'Time target'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Has time target'),
              value: _hasEffort,
              onChanged: (v) => setState(() => _hasEffort = v),
            ),
            if (_hasEffort) ...[
              TextField(
                controller: _minutes,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Target minutes',
                  border: OutlineInputBorder(),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Fixed estimate'),
                value: _effortFixed,
                onChanged: (v) =>
                    setState(() => _effortFixed = v),
              ),
            ],
            const SizedBox(height: 8),
            _sectionTitle(context, 'Repeats'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Repeats'),
              subtitle: const Text(
                  'Habit/budget template — generates dated instances'),
              value: _hasRecurrence,
              onChanged: (v) => setState(() => _hasRecurrence = v),
            ),
            if (_hasRecurrence) ...[
              DropdownButtonFormField<TimeScale>(
                initialValue: _frequency,
                decoration:
                    const InputDecoration(labelText: 'Frequency'),
                items: TimeScale.values
                    .map((s) => DropdownMenuItem(
                        value: s, child: Text(s.displayName)))
                    .toList(),
                onChanged: (v) =>
                    setState(() => _frequency = v ?? _frequency),
              ),
              _DateRow(
                label: _recurEnd == null
                    ? 'Repeats forever'
                    : 'Ends ${MaterialLocalizations.of(context).formatFullDate(_recurEnd!)}',
                onPick: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _recurEnd ??
                        DateTime.now().add(const Duration(days: 365)),
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) {
                    setState(() => _recurEnd = picked);
                  }
                },
                onClear: _recurEnd == null
                    ? null
                    : () => setState(() => _recurEnd = null),
              ),
            ],
            const SizedBox(height: 8),
            _sectionTitle(context, 'Rule'),
            DropdownButtonFormField<NodeRuleKind>(
              initialValue: _ruleKind,
              decoration: const InputDecoration(
                  labelText: 'Derived goal (optional)'),
              items: const [
                DropdownMenuItem(
                    value: NodeRuleKind.none, child: Text('None')),
                DropdownMenuItem(
                    value: NodeRuleKind.homeworkAhead,
                    child: Text('Homework ahead')),
                DropdownMenuItem(
                    value: NodeRuleKind.minBalance,
                    child: Text('Minimum balance')),
              ],
              onChanged: (v) =>
                  setState(() => _ruleKind = v ?? NodeRuleKind.none),
            ),
            if (_ruleKind == NodeRuleKind.homeworkAhead) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _horizon,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Days ahead that must be done'),
              ),
            ],
            if (_ruleKind == NodeRuleKind.minBalance) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _minBalance,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Floor balance', prefixText: '\$ '),
              ),
            ],
            if (e != null && e.hasReported && e.reportedDuration != null) ...[
              const SizedBox(height: 8),
              Text(
                'Reported ${e.reportedDuration!.inMinutes}m '
                '(${DateFormat('h:mm a').format(e.actualStart!)} – '
                '${DateFormat('h:mm a').format(e.actualEnd!)})',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (e != null && e.status == NodeStatus.failed) ...[
              const SizedBox(height: 4),
              Text(
                'Marked as failed — tap its box to unmark.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
              ),
            ],
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        if (e != null)
          TextButton(
            onPressed: () => _delete(context, e),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => _save(context),
          child: Text(e == null ? 'Add' : 'Save'),
        ),
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
      );

  void _save(BuildContext context) {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a title')),
      );
      return;
    }
    final cubit = context.read<NodeCubit>();
    final notes =
        _notes.text.trim().isEmpty ? null : _notes.text.trim();

    ScheduleFacet? schedule;
    if (_due != null ||
        _blockStart != null ||
        _blockEnd != null ||
        _dateFixed) {
      var end = _blockEnd;
      var start = _blockStart;
      if (start != null && end != null && !end.isAfter(start)) {
        end = start.add(const Duration(hours: 1));
      }
      schedule = ScheduleFacet(
        due: _due,
        start: start,
        end: end,
        allDay: _allDay,
        isFixed: _dateFixed,
      );
    }

    MoneyFacet? money;
    if (_hasMoney) {
      final target = double.tryParse(_amount.text.trim()) ?? 0.0;
      money = MoneyFacet(
        targetAmount: target,
        actualAmount: widget.existing?.money?.actualAmount,
        direction: _direction,
        status:
            widget.existing?.money?.status ?? MoneyStatus.projected,
        period: _period,
        customPeriodDays: _period == TimeScale.custom
            ? int.tryParse(_customDaysCtrl.text.trim())
            : null,
        isRecurring: _moneyRecurring,
        autoRollover: _autoRollover,
        rolloverAmount:
            widget.existing?.money?.rolloverAmount ?? 0.0,
        isFixed: _moneyFixed,
        linkedTransactionIds:
            widget.existing?.money?.linkedTransactionIds ?? const [],
      );
    }

    EffortFacet? effort;
    if (_hasEffort) {
      effort = EffortFacet(
        targetMinutes: int.tryParse(_minutes.text.trim()) ?? 0,
        isFixed: _effortFixed,
      );
    }

    NodeRecurrence? recurrence;
    if (_hasRecurrence) {
      recurrence = NodeRecurrence(
        frequency: _frequency,
        endDate: _recurEnd,
      );
    }

    RuleFacet? rule;
    if (_ruleKind != NodeRuleKind.none) {
      rule = RuleFacet(
        kind: _ruleKind,
        horizonDays: int.tryParse(_horizon.text.trim()) ?? 3,
        minBalance: double.tryParse(_minBalance.text.trim()) ?? 0.0,
      );
    }

    final existing = widget.existing;
    String? error;
    if (existing == null) {
      final node = Node(
        id: 'node:${DateTime.now().microsecondsSinceEpoch}',
        title: title,
        notes: notes,
        parentIds: _parents,
        createdAt: DateTime.now(),
        schedule: schedule,
        money: money,
        effort: effort,
        recurrence: recurrence,
        rule: rule,
        assignees: _people,
      );
      error = cubit.addNode(node);
      if (error == null && recurrence != null) {
        cubit.generateInstances(
          templateId: node.id,
          from: DateTime.now(),
          horizon: DateTime.now().add(const Duration(days: 365)),
        );
      }
    } else {
      error = cubit.updateNode(
        existing.copyWith(
          title: title,
          notes: notes,
          clearNotes: notes == null,
          parentIds: _parents,
          schedule: schedule,
          clearSchedule: schedule == null,
          money: money,
          clearMoney: money == null,
          effort: effort,
          clearEffort: effort == null,
          recurrence: recurrence,
          clearRecurrence: recurrence == null,
          rule: rule,
          clearRule: rule == null,
          assignees: _people,
        ),
      );
    }
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
      return;
    }
    Navigator.of(context).pop();
  }

  void _delete(BuildContext context, Node existing) {
    final eventId =
        existing.calendarEventId ?? existing.sourceEventId;
    context.read<NodeCubit>().deleteNode(existing.id);
    if (eventId != null) {
      try {
        context.read<CalendarCubit>().clearTaskLink(eventId);
      } catch (_) {}
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Node deleted'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => context.read<UndoCubit>().undo(),
        ),
      ),
    );
    Navigator.of(context).pop();
  }
}

class _ParentsField extends StatelessWidget {
  final List<String> selected;
  final String? excludeId;
  final ValueChanged<List<String>> onChanged;

  const _ParentsField({
    required this.selected,
    required this.excludeId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final nodes = context.watch<NodeCubit>().state;
    final names = {for (final n in nodes) n.id: n.title};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Parents',
            style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          children: [
            for (final id in selected)
              Chip(
                label: Text(names[id] ?? 'node',
                    overflow: TextOverflow.ellipsis),
                deleteIcon: const Icon(Icons.close, size: 16),
                onDeleted: () => onChanged(
                    selected.where((p) => p != id).toList()),
              ),
            ActionChip(
              avatar: const Icon(Icons.add, size: 16),
              label: const Text('Add parent'),
              onPressed: () => _pick(context, nodes),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _pick(
      BuildContext context, List<Node> nodes) async {
    final excluded = <String>{if (excludeId != null) excludeId!};
    if (excludeId != null) {
      excluded.addAll(descendantIds(excludeId!, nodes));
    }
    final candidates =
        nodes.where((n) => !excluded.contains(n.id)).toList();
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No eligible parents')),
      );
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Add parent'),
        children: [
          for (final n in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(n.id),
              child: Text(
                n.title,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
    if (picked != null && !selected.contains(picked)) {
      onChanged([...selected, picked]);
    }
  }
}

class _DateRow extends StatelessWidget {
  final String label;
  final VoidCallback onPick;
  final VoidCallback? onClear;

  const _DateRow({
    required this.label,
    required this.onPick,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(
          tooltip: 'Pick date',
          icon: const Icon(Icons.event),
          onPressed: onPick,
        ),
        if (onClear != null)
          IconButton(
            tooltip: 'Clear date',
            icon: const Icon(Icons.event_busy),
            onPressed: onClear,
          ),
      ],
    );
  }
}

class _BlockField extends StatelessWidget {
  final DateTime? start;
  final DateTime? end;
  final bool allDay;
  final void Function(DateTime? start, DateTime? end, bool allDay)
      onChanged;

  const _BlockField({
    required this.start,
    required this.end,
    required this.allDay,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final s = start;
    final e = end;
    final label = s != null && e != null && !allDay
        ? '${DateFormat('EEE, MMM d').format(s)} · '
            '${TimeOfDay.fromDateTime(s).format(context)} – '
            '${TimeOfDay.fromDateTime(e).format(context)}'
        : s != null && allDay
            ? '${DateFormat('EEE, MMM d').format(s)} · all day'
            : 'No calendar block';
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Calendar block',
                      style:
                          Theme.of(context).textTheme.labelLarge),
                  Text(label,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Pick block',
              icon: const Icon(Icons.schedule),
              onPressed: () => _pick(context),
            ),
            if (s != null || e != null)
              IconButton(
                tooltip: 'Clear block',
                icon: const Icon(Icons.event_busy),
                onPressed: () => onChanged(null, null, false),
              ),
          ],
        ),
        Row(
          children: [
            const Expanded(child: Text('All day')),
            Switch(
              value: allDay,
              onChanged: s == null
                  ? null
                  : (v) => onChanged(s, e, v),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final initialDate = start ?? now.add(const Duration(days: 1));
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (pickedDate == null || !context.mounted) return;
    final initialStart = start != null
        ? TimeOfDay.fromDateTime(start!)
        : const TimeOfDay(hour: 9, minute: 0);
    final pickedStart = await showTimePicker(
      context: context,
      initialTime: initialStart,
    );
    if (pickedStart == null || !context.mounted) return;
    final initialEnd = end != null
        ? TimeOfDay.fromDateTime(end!)
        : TimeOfDay(
            hour: (pickedStart.hour + 1) % 24,
            minute: pickedStart.minute,
          );
    final pickedEnd = await showTimePicker(
      context: context,
      initialTime: initialEnd,
    );
    if (pickedEnd == null || !context.mounted) return;
    var blockStart = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedStart.hour,
      pickedStart.minute,
    );
    var blockEnd = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedEnd.hour,
      pickedEnd.minute,
    );
    if (!blockEnd.isAfter(blockStart)) {
      blockEnd = blockStart.add(const Duration(hours: 1));
    }
    onChanged(blockStart, blockEnd, allDay);
  }
}
