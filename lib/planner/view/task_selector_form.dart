import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../nodes/bloc/node_cubit.dart';
import '../model/task_filter.dart';

/// The "which tasks" half of a view or rule editor: name, date window,
/// status, kind, classes, and planning. Emits a new [TaskFilter] on every
/// control so both editors stay thin. Includes a live "keeps N rows"
/// preview; cheap (one pass over open nodes).
class TaskSelectorForm extends StatefulWidget {
  final TaskFilter value;
  final ValueChanged<TaskFilter> onChanged;

  const TaskSelectorForm({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  State<TaskSelectorForm> createState() => _TaskSelectorFormState();
}

class _TaskSelectorFormState extends State<TaskSelectorForm> {
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.value.name);
  }

  @override
  void didUpdateWidget(TaskSelectorForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync only when the draft changed elsewhere (switching edited items):
    // our own keystrokes already flow through onChanged into value.
    if (widget.value.name != _name.text &&
        widget.value.name != oldWidget.value.name) {
      _name.text = widget.value.name;
    }
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

  void _emit(TaskFilter next) => widget.onChanged(next);

  void _emitName() {
    final name = _name.text.trim().isEmpty ? 'Filter' : _name.text.trim();
    if (name != widget.value.name) {
      _emit(widget.value.copyWith(name: name));
    } else {
      // Still refresh the preview line.
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.value.copyWith(
      name: _name.text.trim().isEmpty ? 'Filter' : _name.text.trim(),
    );
    final classOptions = _classOptions();
    final classes = Set.of(draft.classKeys)
      ..removeWhere((c) => !classOptions.contains(c));
    final matchCount = _matchCount(draft.copyWith(classKeys: classes.toList()));
    final showUndatedRow =
        draft.date != TaskFilterDate.all && draft.date != TaskFilterDate.undated;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(
            labelText: 'Name',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.words,
          onChanged: (_) => _emitName(),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<TaskFilterDate>(
          initialValue: draft.date,
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
            if (d != null) _emit(draft.copyWith(date: d));
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: draft.showCompleted,
          onChanged: (v) => _emit(draft.copyWith(showCompleted: v)),
          title: const Text('Show completed'),
          subtitle: const Text(
              'Off hides done items while this view is active.'),
        ),
        if (showUndatedRow)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: draft.showUndated,
            onChanged: (v) => _emit(draft.copyWith(showUndated: v)),
            title: const Text('Show undated'),
            subtitle: const Text(
                'Off hides items without a due date in this view.'),
          ),
        const SizedBox(height: 4),
        Text('Tasks', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        SegmentedButton<TaskFilterKind>(
          segments: const [
            ButtonSegment(value: TaskFilterKind.both, label: Text('All')),
            ButtonSegment(
                value: TaskFilterKind.personal, label: Text('Personal')),
            ButtonSegment(
                value: TaskFilterKind.homework, label: Text('Homework')),
          ],
          selected: {draft.kind},
          onSelectionChanged: (s) => _emit(draft.copyWith(kind: s.single)),
        ),
        if (draft.kind != TaskFilterKind.personal &&
            classOptions.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Classes', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              for (final c in classOptions)
                FilterChip(
                  label: Text(c),
                  selected: classes.contains(c),
                  onSelected: (sel) {
                    final next = Set.of(classes);
                    if (sel) {
                      next.add(c);
                    } else {
                      next.remove(c);
                    }
                    _emit(draft.copyWith(
                        classKeys: next.toList()..sort()));
                  },
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
        Text('Planning', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        SegmentedButton<TaskFilterPlanned>(
          segments: const [
            ButtonSegment(value: TaskFilterPlanned.all, label: Text('All')),
            ButtonSegment(
                value: TaskFilterPlanned.plannedOnly, label: Text('Planned')),
            ButtonSegment(
                value: TaskFilterPlanned.unplannedOnly,
                label: Text('Unplanned')),
          ],
          selected: {draft.planned},
          onSelectionChanged: (s) =>
              _emit(draft.copyWith(planned: s.single)),
        ),
        const SizedBox(height: 12),
        Text(
          matchCount == null
              ? describeTaskFilter(draft.copyWith(
                  classKeys: classes.toList()))
              : '${describeTaskFilter(draft.copyWith(classKeys: classes.toList()))}\n'
                  'Keeps $matchCount To-Do row(s) right now.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
