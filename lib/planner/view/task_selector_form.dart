import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../nodes/bloc/node_cubit.dart';
import '../model/task_date_range.dart';
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
            if (d == null) return;
            var next = draft.copyWith(date: d);
            // Switching to the custom window starts from a rolling week
            // so the range controls below have something sane to show.
            if (d == TaskFilterDate.custom && next.customRange == null) {
              next = next.copyWith(
                customRange: const TaskDateRange(
                    startOffsetDays: 0, endOffsetDays: 7),
              );
            }
            _emit(next);
          },
        ),
        if (draft.date == TaskFilterDate.custom) ...[
          const SizedBox(height: 12),
          _CustomRangeSection(
            value: draft.customRange ??
                const TaskDateRange(startOffsetDays: 0, endOffsetDays: 7),
            onChanged: (range) =>
                _emit(draft.copyWith(customRange: range)),
          ),
        ],
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

/// The "which days" half of a custom window: optional start/end as day
/// offsets from today, with presets and a resolved-date preview so a
/// rolling window can be dialed in ("Sunday + 8 days" is start +1, end
/// +9 when today is Saturday — the preview shows the actual dates).
class _CustomRangeSection extends StatelessWidget {
  final TaskDateRange value;
  final ValueChanged<TaskDateRange> onChanged;

  const _CustomRangeSection({required this.value, required this.onChanged});

  void _setStart(int? start) => onChanged(TaskDateRange(
        startOffsetDays: start,
        endOffsetDays: value.endOffsetDays,
      ));

  void _setEnd(int? end) => onChanged(TaskDateRange(
        startOffsetDays: value.startOffsetDays,
        endOffsetDays: end,
      ));

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            _PresetChip(
              label: 'Tomorrow or earlier',
              selected: value.startOffsetDays == null &&
                  value.endOffsetDays == 1,
              onTap: () => onChanged(const TaskDateRange(
                  startOffsetDays: null, endOffsetDays: 1)),
            ),
            _PresetChip(
              label: 'Next 8 days',
              selected: value.startOffsetDays == 0 &&
                  value.endOffsetDays == 8,
              onTap: () => onChanged(const TaskDateRange(
                  startOffsetDays: 0, endOffsetDays: 8)),
            ),
            _PresetChip(
              label: 'Next 30 days',
              selected: value.startOffsetDays == 0 &&
                  value.endOffsetDays == 30,
              onTap: () => onChanged(const TaskDateRange(
                  startOffsetDays: 0, endOffsetDays: 30)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _OffsetRow(
          label: 'From',
          value: value.startOffsetDays,
          unboundedLabel: 'No earlier limit (includes overdue)',
          decrementTooltip: 'Start a day earlier',
          incrementTooltip: 'Start a day later',
          onUnboundedChanged: (unbounded) =>
              _setStart(unbounded ? null : 0),
          onChanged: _setStart,
        ),
        _OffsetRow(
          label: 'To',
          value: value.endOffsetDays,
          unboundedLabel: 'No later limit',
          decrementTooltip: 'End a day earlier',
          incrementTooltip: 'End a day later',
          onUnboundedChanged: (unbounded) => _setEnd(unbounded ? null : 7),
          onChanged: _setEnd,
        ),
        Text(
          resolvedTaskDateRange(value, now),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (!value.isValid)
          Text(
            'Start is after end — no dated tasks match.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
          ),
      ],
    );
  }
}

class _PresetChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PresetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label),
      tooltip: label,
      onPressed: onTap,
      backgroundColor: selected
          ? Theme.of(context).colorScheme.secondaryContainer
          : null,
    );
  }
}

class _OffsetRow extends StatelessWidget {
  final String label;
  final int? value;
  final String unboundedLabel;
  final String decrementTooltip;
  final String incrementTooltip;
  final ValueChanged<bool> onUnboundedChanged;
  final ValueChanged<int> onChanged;

  const _OffsetRow({
    required this.label,
    required this.value,
    required this.unboundedLabel,
    required this.decrementTooltip,
    required this.incrementTooltip,
    required this.onUnboundedChanged,
    required this.onChanged,
  });

  String _valueLabel(int offset) => switch (offset) {
        0 => 'Today',
        1 => 'Tomorrow (+1)',
        -1 => 'Yesterday (−1)',
        > 1 => 'Day +$offset',
        _ => 'Day $offset',
      };

  @override
  Widget build(BuildContext context) {
    final v = value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            SizedBox(
              width: 44,
              child: Text(label,
                  style: Theme.of(context).textTheme.labelLarge),
            ),
            if (v == null)
              Expanded(child: Text(unboundedLabel))
            else ...[
              IconButton(
                tooltip: decrementTooltip,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.remove),
                onPressed: v <= taskDateRangeMinOffset
                    ? null
                    : () => onChanged(
                        clampTaskDateOffset(v - 1)),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    _valueLabel(v),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ),
              IconButton(
                tooltip: incrementTooltip,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add),
                onPressed: v >= taskDateRangeMaxOffset
                    ? null
                    : () => onChanged(
                        clampTaskDateOffset(v + 1)),
              ),
            ],
          ],
        ),
        Row(
          children: [
            const SizedBox(width: 44),
            Expanded(
              child: InkWell(
                onTap: () => onUnboundedChanged(v != null),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: Checkbox(
                          value: v == null,
                          onChanged: (b) =>
                              onUnboundedChanged(b ?? false),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Flexible(child: Text(unboundedLabel)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
