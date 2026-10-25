import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/service/node_calendar.dart';
import '../bloc/calendar_cubit.dart';
import '../model/task_date_range.dart';
import '../model/task_range_bound.dart';
import '../model/task_filter.dart';
import 'class_names.dart';

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
      // Same planned set as the lists: keys of the schedule-tint counts,
      // so the preview agrees with what the applied view will keep.
      Set<String>? plannedIds;
      if (draft.planned != TaskFilterPlanned.all) {
        try {
          final events = context.read<CalendarCubit>().state;
          plannedIds =
              futureCalendarEntryCounts(cubit.state, events, now).keys.toSet();
        } catch (_) {
          // No calendar here: matching falls back to the node's own block.
        }
      }
      var count = 0;
      for (final n in cubit.openNodes) {
        if (draft.matches(n, now, plannedNodeIds: plannedIds)) count++;
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
    final className = classNameResolver(context);
    final classes = Set.of(draft.classKeys)
      ..removeWhere((c) => !classOptions.contains(c));
    final matchCount = _matchCount(draft.copyWith(classKeys: classes.toList()));
    final summary = describeTaskFilter(
      draft.copyWith(classKeys: classes.toList()),
      className: className,
    );
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
                  start: TaskRangeBound.offset(0),
                  end: TaskRangeBound.offset(7),
                ),
              );
            }
            _emit(next);
          },
        ),
        if (draft.date == TaskFilterDate.custom) ...[
          const SizedBox(height: 12),
          _CustomRangeSection(
            value: draft.customRange ??
                const TaskDateRange(
                  start: TaskRangeBound.offset(0),
                  end: TaskRangeBound.offset(7),
                ),
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
                  label: Text(className(c)),
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
              ? summary
              : '$summary\nKeeps $matchCount To-Do row(s) right now.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// The "which days" half of a custom window: each end pins itself as no
/// limit, N days from today, or a named weekday N weeks out — with
/// presets and a resolved-date preview so a rolling window can be dialed
/// in ("overdue to next Monday" is the second preset; "Sunday + 8 days"
/// is From Sunday / To Sunday + 8 — the preview shows the actual dates).
class _CustomRangeSection extends StatelessWidget {
  final TaskDateRange value;
  final ValueChanged<TaskDateRange> onChanged;

  const _CustomRangeSection({required this.value, required this.onChanged});

  void _setStart(TaskRangeBound start) =>
      onChanged(value.copyWith(start: start));

  void _setEnd(TaskRangeBound end) => onChanged(value.copyWith(end: end));

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
              selected: value.start.isUnbounded &&
                  value.end == const TaskRangeBound.offset(1),
              onTap: () => onChanged(const TaskDateRange(
                start: TaskRangeBound.unbounded(),
                end: TaskRangeBound.offset(1),
              )),
            ),
            _PresetChip(
              label: 'To next Monday',
              selected: value.start.isUnbounded &&
                  value.end ==
                      const TaskRangeBound.weekday(
                          weekday: DateTime.monday, weeksOut: 1),
              onTap: () => onChanged(const TaskDateRange(
                start: TaskRangeBound.unbounded(),
                end: TaskRangeBound.weekday(
                    weekday: DateTime.monday, weeksOut: 1),
              )),
            ),
            _PresetChip(
              label: 'Next 8 days',
              selected: value.start == const TaskRangeBound.offset(0) &&
                  value.end == const TaskRangeBound.offset(8),
              onTap: () => onChanged(const TaskDateRange(
                start: TaskRangeBound.offset(0),
                end: TaskRangeBound.offset(8),
              )),
            ),
            _PresetChip(
              label: 'Next 30 days',
              selected: value.start == const TaskRangeBound.offset(0) &&
                  value.end == const TaskRangeBound.offset(30),
              onTap: () => onChanged(const TaskDateRange(
                start: TaskRangeBound.offset(0),
                end: TaskRangeBound.offset(30),
              )),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _BoundRow(
          label: 'From',
          value: value.start,
          anyLabel: 'Any time',
          defaultOffset: 0,
          onChanged: _setStart,
        ),
        _BoundRow(
          label: 'To',
          value: value.end,
          anyLabel: 'No limit',
          defaultOffset: 7,
          onChanged: _setEnd,
        ),
        Text(
          resolvedTaskDateRange(value, now),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (!value.isValidAt(now))
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

/// One pinned end of the range: how it anchors (no limit, days from
/// today, or a named weekday), plus the control for the chosen anchor.
class _BoundRow extends StatelessWidget {
  final String label;
  final TaskRangeBound value;
  final String anyLabel;
  final int defaultOffset;
  final ValueChanged<TaskRangeBound> onChanged;

  const _BoundRow({
    required this.label,
    required this.value,
    required this.anyLabel,
    required this.defaultOffset,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
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
            Expanded(
              child: Wrap(
                spacing: 4,
                children: [
                  ChoiceChip(
                    label: Text(anyLabel),
                    selected: value.kind == TaskRangeBoundKind.unbounded,
                    onSelected: (_) =>
                        onChanged(const TaskRangeBound.unbounded()),
                  ),
                  ChoiceChip(
                    label: const Text('Days'),
                    selected: value.kind == TaskRangeBoundKind.offset,
                    onSelected: (_) =>
                        onChanged(TaskRangeBound.offset(defaultOffset)),
                  ),
                  ChoiceChip(
                    label: const Text('Weekday'),
                    selected: value.kind == TaskRangeBoundKind.weekday,
                    // This week, not next: switching anchor must not jump
                    // the bound a week ahead before the user picks.
                    onSelected: (_) => onChanged(
                        const TaskRangeBound.weekday(
                            weekday: DateTime.monday, weeksOut: 0)),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            const SizedBox(width: 44),
            Expanded(
              child: switch (value.kind) {
                TaskRangeBoundKind.unbounded => Text(
                    label == 'From'
                        ? 'Includes overdue items.'
                        : 'Never cuts off the future.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                TaskRangeBoundKind.offset => _DayStepper(
                    value: value.offsetDays,
                    decrementTooltip: '$label a day earlier',
                    incrementTooltip: '$label a day later',
                    onChanged: (v) =>
                        onChanged(TaskRangeBound.offset(v)),
                  ),
                TaskRangeBoundKind.weekday => _WeekdayPicker(
                    weekday: value.weekday,
                    weeksOut: value.weeksOut,
                    onChanged: (weekday, weeksOut) => onChanged(
                        TaskRangeBound.weekday(
                            weekday: weekday, weeksOut: weeksOut)),
                  ),
              },
            ),
          ],
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}

class _DayStepper extends StatelessWidget {
  final int value;
  final String decrementTooltip;
  final String incrementTooltip;
  final ValueChanged<int> onChanged;

  const _DayStepper({
    required this.value,
    required this.decrementTooltip,
    required this.incrementTooltip,
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
    return Row(
      children: [
        IconButton(
          tooltip: decrementTooltip,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove),
          onPressed: value <= taskDateRangeMinOffset
              ? null
              : () => onChanged(clampTaskDateOffset(value - 1)),
        ),
        Expanded(
          child: Center(
            child: Text(
              _valueLabel(value),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        ),
        IconButton(
          tooltip: incrementTooltip,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add),
          onPressed: value >= taskDateRangeMaxOffset
              ? null
              : () => onChanged(clampTaskDateOffset(value + 1)),
        ),
      ],
    );
  }
}

class _WeekdayPicker extends StatelessWidget {
  final int weekday;
  final int weeksOut;
  final void Function(int weekday, int weeksOut) onChanged;

  const _WeekdayPicker({
    required this.weekday,
    required this.weeksOut,
    required this.onChanged,
  });

  // Negative entries reach earlier weeks: with Monday-start weeks,
  // "Sunday of last week" is the Sunday that just passed for most
  // readers, which the old 0-floor picker could not express at all.
  static const _weekValues = [-2, -1, 0, 1, 2, 3];
  static const _weekLabels = [
    '2 weeks ago',
    'Last week',
    'This week',
    'Next week',
    'In 2 weeks',
    'In 3 weeks'
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: DropdownButton<int>(
            value: weekday,
            isExpanded: true,
            items: [
              for (var d = DateTime.monday; d <= DateTime.sunday; d++)
                DropdownMenuItem(
                  value: d,
                  child: Text(taskRangeWeekdayName(d)),
                ),
            ],
            onChanged: (d) {
              if (d != null) onChanged(d, weeksOut);
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButton<int>(
            value: weeksOut.clamp(_weekValues.first, _weekValues.last),
            isExpanded: true,
            items: [
              for (var i = 0; i < _weekValues.length; i++)
                DropdownMenuItem(
                  value: _weekValues[i],
                  child: Text(_weekLabels[i]),
                ),
            ],
            onChanged: (w) {
              if (w != null) onChanged(weekday, w);
            },
          ),
        ),
      ],
    );
  }
}
