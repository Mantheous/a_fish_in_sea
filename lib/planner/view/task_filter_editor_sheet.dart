import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../nodes/bloc/node_cubit.dart';
import '../bloc/tasks_view_options_cubit.dart';
import '../model/task_filter.dart';

/// Builder for one saved Tasks view: name, date window, and the extra
/// rules (status, kind, classes, planning). The legacy All/Today/Overdue
/// presets open here too — they are just editable filters.
Future<void> showTaskFilterEditor(
  BuildContext context, {
  TaskFilter? existing,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => _TaskFilterEditorSheet(existing: existing),
  );
}

class _TaskFilterEditorSheet extends StatefulWidget {
  final TaskFilter? existing;

  const _TaskFilterEditorSheet({this.existing});

  @override
  State<_TaskFilterEditorSheet> createState() => _TaskFilterEditorSheetState();
}

class _TaskFilterEditorSheetState extends State<_TaskFilterEditorSheet> {
  late final TextEditingController _name;
  late TaskFilterDate _date;
  late bool _showCompleted;
  late bool _showUndated;
  late TaskFilterKind _kind;
  late Set<String> _classes;
  late TaskFilterPlanned _planned;

  bool get _editingAll => widget.existing?.id == 'all';

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? 'Custom filter');
    _date = e?.date ?? TaskFilterDate.next7Days;
    _showCompleted = e?.showCompleted ?? false;
    _showUndated = e?.showUndated ?? false;
    _kind = e?.kind ?? TaskFilterKind.both;
    _classes = Set.of(e?.classKeys ?? const []);
    _planned = e?.planned ?? TaskFilterPlanned.all;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Distinct homework class keys across all nodes, for the class picker.
  /// Falls back to empty when the cubit isn't provided.
  List<String> _classOptions() {
    try {
      final nodes = context.read<NodeCubit>().state;
      final keys = <String>{};
      for (final n in nodes) {
        if (!n.isHomework) continue;
        keys.add(n.classLabel ?? n.classId ?? '');
      }
      keys.remove('');
      return keys.toList()..sort();
    } catch (_) {
      return const [];
    }
  }

  /// Live preview: how many To-Do rows the draft keeps. Cheap (one pass).
  int? _matchCount(TaskFilter draft) {
    try {
      final cubit = context.read<NodeCubit>();
      final now = DateTime.now();
      if (draft.isShowAll) return cubit.openNodes.length;
      var count = 0;
      for (final n in cubit.openNodes) {
        if (draft.matches(n, now)) count++;
      }
      return count;
    } catch (_) {
      return null;
    }
  }

  TaskFilter _draft() => TaskFilter(
        id: widget.existing?.id ?? TaskFilter.newId(),
        name: _name.text.trim().isEmpty ? 'Filter' : _name.text.trim(),
        date: _date,
        showCompleted: _showCompleted,
        showUndated: _showUndated,
        kind: _kind,
        classKeys: _classes.toList()..sort(),
        planned: _planned,
      );

  void _save() {
    try {
      final cubit = context.read<TasksViewOptionsCubit>();
      final draft = _draft();
      if (widget.existing == null) {
        cubit.addFilter(draft);
      } else {
        cubit.updateFilter(draft);
        cubit.setActiveFilter(draft.id);
      }
    } catch (_) {}
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    final classOptions = _classOptions();
    // Drop classes that no longer exist so the draft never references
    // a deleted class.
    _classes.removeWhere((c) => !classOptions.contains(c));
    final draft = _draft();
    final matchCount = _matchCount(draft);
    final showUndatedRow =
        _date != TaskFilterDate.all && _date != TaskFilterDate.undated;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      existing == null ? 'New filter' : 'Edit filter',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (existing != null && !_editingAll)
                    TextButton(
                      onPressed: () {
                        try {
                          context
                              .read<TasksViewOptionsCubit>()
                              .deleteFilter(existing.id);
                        } catch (_) {}
                        Navigator.of(context).pop();
                      },
                      child: const Text('Delete'),
                    ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      border: OutlineInputBorder(),
                    ),
                    textCapitalization: TextCapitalization.words,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<TaskFilterDate>(
                    initialValue: _date,
                    decoration: const InputDecoration(
                      labelText: 'Date range',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final d in TaskFilterDate.values)
                        DropdownMenuItem(
                          value: d,
                          child: Text(taskFilterDateLabel(d)),
                        ),
                    ],
                    onChanged: (d) {
                      if (d != null) setState(() => _date = d);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _showCompleted,
                    onChanged: (v) => setState(() => _showCompleted = v),
                    title: const Text('Show completed'),
                    subtitle: const Text(
                        'Off hides done items while this view is active.'),
                  ),
                  if (showUndatedRow)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _showUndated,
                      onChanged: (v) => setState(() => _showUndated = v),
                      title: const Text('Show undated'),
                      subtitle: const Text(
                          'Off hides items without a due date in this view.'),
                    ),
                  const SizedBox(height: 4),
                  Text('Tasks',
                      style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  SegmentedButton<TaskFilterKind>(
                    segments: const [
                      ButtonSegment(
                          value: TaskFilterKind.both, label: Text('All')),
                      ButtonSegment(
                          value: TaskFilterKind.personal,
                          label: Text('Personal')),
                      ButtonSegment(
                          value: TaskFilterKind.homework,
                          label: Text('Homework')),
                    ],
                    selected: {_kind},
                    onSelectionChanged: (s) =>
                        setState(() => _kind = s.single),
                  ),
                  if (_kind != TaskFilterKind.personal &&
                      classOptions.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text('Classes',
                        style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final c in classOptions)
                          FilterChip(
                            label: Text(c),
                            selected: _classes.contains(c),
                            onSelected: (sel) => setState(() {
                              if (sel) {
                                _classes.add(c);
                              } else {
                                _classes.remove(c);
                              }
                            }),
                          ),
                      ],
                    ),
                    Text(
                      'Empty means every class. Personal tasks always '
                      'pass the class picker.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text('Planning',
                      style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  SegmentedButton<TaskFilterPlanned>(
                    segments: const [
                      ButtonSegment(
                          value: TaskFilterPlanned.all, label: Text('All')),
                      ButtonSegment(
                          value: TaskFilterPlanned.plannedOnly,
                          label: Text('Planned')),
                      ButtonSegment(
                          value: TaskFilterPlanned.unplannedOnly,
                          label: Text('Unplanned')),
                    ],
                    selected: {_planned},
                    onSelectionChanged: (s) =>
                        setState(() => _planned = s.single),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    matchCount == null
                        ? describeTaskFilter(draft)
                        : '${describeTaskFilter(draft)}\n'
                            'Keeps $matchCount To-Do row(s) right now.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _save,
                    child: Text(existing == null ? 'Add filter' : 'Save'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
