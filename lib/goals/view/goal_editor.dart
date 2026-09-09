import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/goals/bloc/goal_cubit.dart';
import 'package:a_fish_in_sea/goals/bloc/tag_cubit.dart';
import 'package:a_fish_in_sea/goals/model/goal.dart';
import 'package:a_fish_in_sea/goals/model/tag.dart';

Future<void> showGoalEditor(BuildContext context, {Goal? existing}) {
  return showDialog(
    context: context,
    builder: (_) => BlocProvider.value(
      value: context.read<GoalCubit>(),
      child: BlocProvider.value(
        value: context.read<TagCubit>(),
        child: _GoalDialog(existing: existing),
      ),
    ),
  );
}

Future<void> showTagEditor(BuildContext context, {GoalTag? existing}) {
  return showDialog(
    context: context,
    builder: (_) => BlocProvider.value(
      value: context.read<TagCubit>(),
      child: _TagDialog(existing: existing),
    ),
  );
}

class _GoalDialog extends StatefulWidget {
  final Goal? existing;
  const _GoalDialog({this.existing});

  @override
  State<_GoalDialog> createState() => _GoalDialogState();
}

class _GoalDialogState extends State<_GoalDialog> {
  late final TextEditingController _title;
  late final TextEditingController _notes;
  late final TextEditingController _targetMinutes;
  late final TextEditingController _targetAmount;
  late GoalType _type;
  late String? _parentId;
  late Set<String> _tagIds;
  late DateTime _start;
  late DateTime? _deadline;
  late bool _showInTasks;
  late TimeScale _period;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: e?.title ?? '');
    _notes = TextEditingController(text: e?.notes ?? '');
    _targetMinutes =
        TextEditingController(text: e?.targetMinutes?.toString() ?? '');
    _targetAmount =
        TextEditingController(text: e?.targetAmount?.toString() ?? '');
    _type = e?.type ?? GoalType.checklist;
    _parentId = e?.parentId;
    _tagIds = {...?e?.tagIds};
    _start = e?.startDate ?? DateTime.now();
    _deadline = e?.deadline;
    _showInTasks = e?.showInTasks ?? false;
    _period = e?.period ?? TimeScale.monthly;
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _targetMinutes.dispose();
    _targetAmount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final goals = context.watch<GoalCubit>().state;
    final tags = context.watch<TagCubit>().state;
    final dateFmt = DateFormat('MMM d, y');
    final candidates = [
      for (final g in goals)
        if (widget.existing == null || g.id != widget.existing!.id)
          if (canNest(g.type, _type)) g
    ];
    if (_parentId != null && candidates.every((g) => g.id != _parentId)) {
      _parentId = null;
    }

    return AlertDialog(
      title: Text(widget.existing == null ? 'New goal' : 'Edit goal'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            TextField(
              controller: _notes,
              decoration: const InputDecoration(labelText: 'Notes'),
            ),
            DropdownButton<GoalType>(
              value: _type,
              items: [
                for (final t in GoalType.values)
                  DropdownMenuItem(value: t, child: Text(t.name)),
              ],
              onChanged: (t) {
                if (t == null) return;
                setState(() {
                  _type = t;
                  if (t != GoalType.checklist) _showInTasks = false;
                });
              },
            ),
            DropdownButton<String?>(
              value: _parentId,
              isExpanded: true,
              hint: const Text('No parent (top-level)'),
              items: [
                const DropdownMenuItem(
                    value: null, child: Text('No parent (top-level)')),
                for (final g in candidates)
                  DropdownMenuItem(value: g.id, child: Text(g.title)),
              ],
              onChanged: (v) => setState(() => _parentId = v),
            ),
            Row(
              children: [
                Text('Start: ${dateFmt.format(_start)}'),
                TextButton(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _start,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) setState(() => _start = picked);
                  },
                  child: const Text('Pick'),
                ),
              ],
            ),
            Row(
              children: [
                Text(_deadline == null
                    ? 'Deadline: required'
                    : 'Deadline: ${dateFmt.format(_deadline!)}'),
                TextButton(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _deadline ?? DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) setState(() => _deadline = picked);
                  },
                  child: const Text('Pick'),
                ),
              ],
            ),
            if (_type == GoalType.checklist)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show in Tasks'),
                value: _showInTasks,
                onChanged: (v) => setState(() => _showInTasks = v),
              ),
            if (_type == GoalType.time)
              TextField(
                controller: _targetMinutes,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Target minutes'),
              ),
            if (_type == GoalType.financial) ...[
              TextField(
                controller: _targetAmount,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Target amount'),
              ),
              DropdownButton<TimeScale>(
                value: _period,
                items: [
                  for (final p in TimeScale.values)
                    DropdownMenuItem(
                        value: p, child: Text(p.displayName)),
                ],
                onChanged: (p) {
                  if (p != null) setState(() => _period = p);
                },
              ),
            ],
            const SizedBox(height: 8),
            const Text('Tags'),
            Wrap(
              spacing: 4,
              children: [
                for (final t in tags)
                  FilterChip(
                    label: Text(t.name),
                    selected: _tagIds.contains(t.id),
                    onSelected: (sel) => setState(() {
                      if (sel) {
                        _tagIds.add(t.id);
                      } else {
                        _tagIds.remove(t.id);
                      }
                    }),
                  ),
              ],
            ),
            TextButton.icon(
              onPressed: () => showTagEditor(context),
              icon: const Icon(Icons.add),
              label: const Text('New tag'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty || _deadline == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Title and deadline are required.')),
      );
      return;
    }
    final cubit = context.read<GoalCubit>();
    final draft = Goal(
      id: widget.existing?.id ??
          'goal:${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      type: _type,
      parentId: _parentId,
      tagIds: _tagIds.toList(),
      startDate: _start,
      deadline: _deadline!,
      done: widget.existing?.done ?? false,
      completedAt: widget.existing?.completedAt,
      failed: widget.existing?.failed ?? false,
      showInTasks: _type == GoalType.checklist && _showInTasks,
      targetMinutes: _type == GoalType.time
          ? int.tryParse(_targetMinutes.text.trim())
          : null,
      targetAmount: _type == GoalType.financial
          ? double.tryParse(_targetAmount.text.trim())
          : null,
      period: _type == GoalType.financial ? _period : null,
      isRecurring: widget.existing?.isRecurring ?? true,
      autoRollover: widget.existing?.autoRollover ?? true,
      rolloverAmount: widget.existing?.rolloverAmount ?? 0.0,
    );
    final error = widget.existing == null
        ? cubit.addGoal(draft)
        : cubit.updateGoal(draft);
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    Navigator.of(context).pop();
  }
}

class _TagDialog extends StatefulWidget {
  final GoalTag? existing;
  const _TagDialog({this.existing});

  @override
  State<_TagDialog> createState() => _TagDialogState();
}

class _TagDialogState extends State<_TagDialog> {
  late final TextEditingController _name;
  late final TextEditingController _category;
  late String? _parentId;
  late TagReporting _reporting;
  String? _placeId;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _category = TextEditingController(text: e?.category ?? '');
    _parentId = e?.parentId;
    _reporting = e?.reporting ?? TagReporting.manual;
    _placeId = e?.placeId;
  }

  @override
  void dispose() {
    _name.dispose();
    _category.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tags = context.watch<TagCubit>().state;
    final candidates = [
      for (final t in tags)
        if (widget.existing == null || t.id != widget.existing!.id) t
    ];
    return AlertDialog(
      title: Text(widget.existing == null ? 'New tag' : 'Edit tag'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            DropdownButton<String?>(
              value: _parentId,
              isExpanded: true,
              hint: const Text('No parent tag'),
              items: [
                const DropdownMenuItem(
                    value: null, child: Text('No parent tag')),
                for (final t in candidates)
                  DropdownMenuItem(value: t.id, child: Text(t.name)),
              ],
              onChanged: (v) => setState(() => _parentId = v),
            ),
            DropdownButton<TagReporting>(
              value: _reporting,
              items: [
                for (final r in TagReporting.values)
                  DropdownMenuItem(value: r, child: Text(r.name)),
              ],
              onChanged: (r) {
                if (r != null) setState(() => _reporting = r);
              },
            ),
            if (_reporting == TagReporting.financialAuto)
              TextField(
                controller: _category,
                decoration: const InputDecoration(
                    labelText: 'Budget category'),
              ),
            if (_reporting == TagReporting.timeAuto)
              TextField(
                decoration:
                    const InputDecoration(labelText: 'Place ID (optional)'),
                controller:
                    TextEditingController(text: _placeId ?? ''),
                onChanged: (v) =>
                    _placeId = v.trim().isEmpty ? null : v.trim(),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tag name is required.')),
      );
      return;
    }
    final cubit = context.read<TagCubit>();
    if (widget.existing != null &&
        cubit.createsCycle(widget.existing!.id, _parentId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('That parent would create a cycle.')),
      );
      return;
    }
    final tag = GoalTag(
      id: widget.existing?.id ??
          'tag:${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      parentId: _parentId,
      reporting: _reporting,
      placeId: _reporting == TagReporting.timeAuto ? _placeId : null,
      category: _reporting == TagReporting.financialAuto &&
              _category.text.trim().isNotEmpty
          ? _category.text.trim()
          : null,
    );
    if (widget.existing == null) {
      cubit.addTag(tag);
    } else {
      cubit.updateTag(tag);
    }
    Navigator.of(context).pop();
  }
}
