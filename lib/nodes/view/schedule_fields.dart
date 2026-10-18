import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../bloc/schedule_prefs_cubit.dart';

final _dayFormat = DateFormat('EEE, MMM d');

/// Local edit state for the unified schedule sheet. Day mode edits the
/// due date inline; Time mode never edits times inline — a time is
/// always a calendar event picked visually on the calendar.
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

/// Day/Time toggle. Stateless: the sheet holds [draft]; Time mode
/// delegates to [onPickCalendar] instead of editing times inline.
class ScheduleFields extends StatelessWidget {
  final ScheduleDraft draft;
  final ValueChanged<ScheduleDraft> onChanged;
  final VoidCallback onPickCalendar;

  const ScheduleFields({
    super.key,
    required this.draft,
    required this.onChanged,
    required this.onPickCalendar,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
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
          onSelectionChanged: (s) {
            final next = draft.copy()..mode = s.single;
            onChanged(next);
          },
        ),
        const SizedBox(height: 12),
        if (draft.mode == ScheduleGranularity.day)
          _DayFields(draft: draft, onChanged: onChanged)
        else
          _TimedInfo(
            draft: draft,
            onChanged: onChanged,
            onPickCalendar: onPickCalendar,
          ),
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

/// Time mode: times are calendar events, so there are no inline
/// pickers — only the current block summary, a way to clear it, and
/// the calendar launcher.
class _TimedInfo extends StatelessWidget {
  final ScheduleDraft draft;
  final ValueChanged<ScheduleDraft> onChanged;
  final VoidCallback onPickCalendar;

  const _TimedInfo({
    required this.draft,
    required this.onChanged,
    required this.onPickCalendar,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Times are calendar events — pick them by looking at the calendar.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        if (draft.hasBlock)
          Text(
            'Currently ${_dayFormat.format(draft.blockStart!)} '
            '· ${TimeOfDay.fromDateTime(draft.blockStart!).format(context)} – '
            '${TimeOfDay.fromDateTime(draft.blockEnd!).format(context)}',
            style: theme.textTheme.bodySmall,
          )
        else
          Text(
            'No time set.',
            style: theme.textTheme.bodySmall,
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: onPickCalendar,
          icon: const Icon(Icons.calendar_month, size: 18),
          label: const Text('Pick time on calendar'),
        ),
        if (draft.hasBlock) ...[
          const SizedBox(height: 4),
          OutlinedButton.icon(
            onPressed: () {
              final next = draft.copy()
                ..blockStart = null
                ..blockEnd = null;
              onChanged(next);
            },
            icon: const Icon(Icons.event_busy, size: 18),
            label: const Text('Clear time block'),
          ),
        ],
      ],
    );
  }
}
