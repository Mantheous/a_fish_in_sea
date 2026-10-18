import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../bloc/schedule_prefs_cubit.dart';

final _fullDateFormat = DateFormat('EEE, MMM d, yyyy');
final _dayFormat = DateFormat('EEE, MMM d');

/// Local edit state shared by the node editor Schedule section and the
/// unified schedule sheet. Both write the same backend ([due] + block):
/// day mode edits the due date, timed mode edits the calendar block.
/// Untouched halves are preserved on save — clearing one never clears
/// the other.
class ScheduleDraft {
  DateTime? due;
  bool fixed;
  DateTime? blockStart;
  DateTime? blockEnd;
  ScheduleGranularity mode;

  ScheduleDraft({
    this.due,
    this.fixed = false,
    this.blockStart,
    this.blockEnd,
    this.mode = ScheduleGranularity.day,
  });

  ScheduleDraft copy() => ScheduleDraft(
        due: due,
        fixed: fixed,
        blockStart: blockStart,
        blockEnd: blockEnd,
        mode: mode,
      );

  bool get hasBlock =>
      blockStart != null &&
      blockEnd != null &&
      blockEnd!.isAfter(blockStart!);
}

/// Day/Time toggle + pickers. Stateless: the owner holds [draft] and
/// applies `onChanged(draft.copy()..mutate)` so the editor (local save)
/// and the sheet (immediate save) share one UI.
class ScheduleFields extends StatelessWidget {
  final ScheduleDraft draft;
  final ValueChanged<ScheduleDraft> onChanged;
  final bool showModeToggle;

  const ScheduleFields({
    super.key,
    required this.draft,
    required this.onChanged,
    this.showModeToggle = true,
  });

  void _update(ScheduleDraft Function(ScheduleDraft d) mutate) {
    final next = draft.copy();
    mutate(next);
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showModeToggle)
          SegmentedButton<ScheduleGranularity>(
            segments: const [
              ButtonSegment(
                value: ScheduleGranularity.day,
                icon: Icon(Icons.event, size: 16),
                label: Text('Day'),
              ),
              ButtonSegment(
                value: ScheduleGranularity.timed,
                icon: Icon(Icons.schedule, size: 16),
                label: Text('Time'),
              ),
            ],
            selected: {draft.mode},
            onSelectionChanged: (s) => _update((d) {
              d.mode = s.single;
              return d;
            }),
          ),
        if (showModeToggle) const SizedBox(height: 12),
        if (draft.mode == ScheduleGranularity.day)
          _DayFields(draft: draft, onChanged: onChanged)
        else
          _TimedFields(draft: draft, onChanged: onChanged),
      ],
    );
  }
}

class _DayFields extends StatelessWidget {
  final ScheduleDraft draft;
  final ValueChanged<ScheduleDraft> onChanged;

  const _DayFields({required this.draft, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final label = draft.due == null
        ? 'No due date'
        : 'Due ${MaterialLocalizations.of(context).formatFullDate(draft.due!)}${draft.fixed ? ' · fixed' : ''}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            IconButton(
              tooltip: 'Pick date',
              icon: const Icon(Icons.event),
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: draft.due ?? DateTime.now(),
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) {
                  final next = draft.copy()..due = picked;
                  onChanged(next);
                }
              },
            ),
            if (draft.due != null)
              IconButton(
                tooltip: 'Clear date',
                icon: const Icon(Icons.event_busy),
                onPressed: () {
                  final next = draft.copy()..due = null;
                  onChanged(next);
                },
              ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Fixed date'),
          subtitle: const Text('Commitment; estimates stay flexible'),
          value: draft.fixed,
          onChanged: (v) {
            final next = draft.copy()..fixed = v;
            onChanged(next);
          },
        ),
      ],
    );
  }
}

class _TimedFields extends StatelessWidget {
  final ScheduleDraft draft;
  final ValueChanged<ScheduleDraft> onChanged;

  const _TimedFields({required this.draft, required this.onChanged});

  DateTime get _blockDate =>
      draft.blockStart ?? draft.due ?? DateTime.now();

  TimeOfDay _startOf(DateTime? dt) =>
      dt == null ? const TimeOfDay(hour: 9, minute: 0) : TimeOfDay.fromDateTime(dt);

  TimeOfDay _endOf(DateTime? dt, DateTime? start) {
    if (dt != null && start != null && dt.isAfter(start)) {
      return TimeOfDay.fromDateTime(dt);
    }
    if (dt != null && start == null) return TimeOfDay.fromDateTime(dt);
    final s = _startOf(start);
    final endMinutes = (s.hour * 60 + s.minute + 60) % (24 * 60);
    return TimeOfDay(
        hour: endMinutes ~/ 60, minute: endMinutes % 60);
  }

  Future<void> _pickDate(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _blockDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    final start = _startOf(draft.blockStart);
    var end = _endOf(draft.blockEnd, draft.blockStart);
    var blockStart = DateTime(
        picked.year, picked.month, picked.day, start.hour, start.minute);
    var blockEnd =
        DateTime(picked.year, picked.month, picked.day, end.hour, end.minute);
    if (!blockEnd.isAfter(blockStart)) {
      blockEnd = blockStart.add(const Duration(hours: 1));
    }
    final next = draft.copy()
      ..blockStart = blockStart
      ..blockEnd = blockEnd;
    onChanged(next);
  }

  Future<void> _pickStart(BuildContext context) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _startOf(draft.blockStart),
    );
    if (picked == null) return;
    final day = _blockDate;
    final blockStart =
        DateTime(day.year, day.month, day.day, picked.hour, picked.minute);
    var blockEnd = draft.blockEnd;
    if (blockEnd == null || !blockEnd.isAfter(blockStart)) {
      blockEnd = blockStart.add(const Duration(hours: 1));
    }
    final next = draft.copy()
      ..blockStart = blockStart
      ..blockEnd = blockEnd;
    onChanged(next);
  }

  Future<void> _pickEnd(BuildContext context) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _endOf(draft.blockEnd, draft.blockStart),
    );
    if (picked == null) return;
    final day = _blockDate;
    var blockEnd =
        DateTime(day.year, day.month, day.day, picked.hour, picked.minute);
    final blockStart = draft.blockStart ??
        DateTime(day.year, day.month, day.day, 9, 0);
    if (!blockEnd.isAfter(blockStart)) {
      blockEnd = blockEnd.add(const Duration(days: 1));
    }
    final next = draft.copy()
      ..blockStart = blockStart
      ..blockEnd = blockEnd;
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final dateLabel = _dayFormat.format(_blockDate);
    final start = _startOf(draft.blockStart);
    final end = _endOf(draft.blockEnd, draft.blockStart);
    final hasBlock = draft.hasBlock;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Date: $dateLabel')),
            IconButton(
              tooltip: 'Pick date',
              icon: const Icon(Icons.event),
              onPressed: () => _pickDate(context),
            ),
            if (hasBlock)
              IconButton(
                tooltip: 'Clear time block',
                icon: const Icon(Icons.event_busy),
                onPressed: () {
                  final next = draft.copy()
                    ..blockStart = null
                    ..blockEnd = null;
                  onChanged(next);
                },
              ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Start'),
                child: InkWell(
                  onTap: () => _pickStart(context),
                  child: Text(
                      '${start.hourOfPeriod == 0 ? 12 : start.hourOfPeriod}:${start.minute.toString().padLeft(2, '0')} ${start.period.name.toUpperCase()}'),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'End'),
                child: InkWell(
                  onTap: () => _pickEnd(context),
                  child: Text(
                      '${end.hourOfPeriod == 0 ? 12 : end.hourOfPeriod}:${end.minute.toString().padLeft(2, '0')} ${end.period.name.toUpperCase()}'),
                ),
              ),
            ),
          ],
        ),
        if (!hasBlock)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'No time set — pick a start and end to place this on the calendar.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Planned ${_fullDateFormat.format(draft.blockStart!)} · ${_formatRange(start, end)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  String _formatRange(TimeOfDay s, TimeOfDay e) {
    String fmt(TimeOfDay t) =>
        '${t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod}:${t.minute.toString().padLeft(2, '0')} ${t.period.name.toUpperCase()}';
    return '${fmt(s)} – ${fmt(e)}';
  }
}
