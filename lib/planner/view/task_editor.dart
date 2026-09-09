import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../common/undo/undo_cubit.dart';
import '../bloc/calendar_cubit.dart';
import '../bloc/task_cubit.dart';
import '../model/task.dart';
import '../model/task_assignee.dart';
import 'people_field.dart';

Future<void> showTaskEditor(
  BuildContext context, {
  Task? existing,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => _TaskEditorDialog(existing: existing),
  );
}

class _TaskEditorDialog extends StatefulWidget {
  final Task? existing;

  const _TaskEditorDialog({this.existing});

  @override
  State<_TaskEditorDialog> createState() => _TaskEditorDialogState();
}

class _TaskEditorDialogState extends State<_TaskEditorDialog> {
  late final TextEditingController _title;
  late final TextEditingController _notes;
  late DateTime? _due;
  DateTime? _plannedStart;
  DateTime? _plannedEnd;
  late List<TaskAssignee> _people;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.existing?.title ?? '');
    _notes = TextEditingController(text: widget.existing?.notes ?? '');
    _due = widget.existing?.due;
    _plannedStart = widget.existing?.plannedStart;
    _plannedEnd = widget.existing?.plannedEnd;
    _people = List.of(widget.existing?.assignees ?? const []);
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New task' : 'Edit task'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _title,
              autofocus: widget.existing == null,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _due == null
                        ? 'No due date'
                        : 'Due ${MaterialLocalizations.of(context).formatFullDate(_due!)}',
                  ),
                ),
                IconButton(
                  tooltip: 'Pick due date',
                  icon: const Icon(Icons.event),
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _due ?? DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) setState(() => _due = picked);
                  },
                ),
                IconButton(
                  tooltip: 'Clear due date',
                  icon: const Icon(Icons.event_busy),
                  onPressed: () => setState(() => _due = null),
                ),
              ],
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
            PeopleField(
              selected: _people,
              onChanged: (next) => setState(() => _people = next),
            ),
            const SizedBox(height: 12),
            _PlannedBlockField(
              plannedStart: _plannedStart,
              plannedEnd: _plannedEnd,
              onChanged: (start, end) => setState(() {
                _plannedStart = start;
                _plannedEnd = end;
              }),
            ),
            if (widget.existing != null &&
                widget.existing!.hasReported &&
                widget.existing!.reportedDuration != null) ...[
              const SizedBox(height: 8),
              Text(
                'Reported ${widget.existing!.reportedDuration!.inMinutes}m '
                '(${DateFormat('h:mm a').format(widget.existing!.actualStart!)} – '
                '${DateFormat('h:mm a').format(widget.existing!.actualEnd!)})',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (widget.existing != null && widget.existing!.failed) ...[
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
        if (widget.existing != null)
          TextButton(
            onPressed: () => _delete(context),
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
          child: Text(widget.existing == null ? 'Add' : 'Save'),
        ),
      ],
    );
  }

  void _save(BuildContext context) {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a title')),
      );
      return;
    }
    final cubit = context.read<TaskCubit>();
    if (widget.existing == null) {
      cubit.addTask(Task(
        id: 'task:${DateTime.now().microsecondsSinceEpoch}',
        title: title,
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        due: _due,
        plannedStart: _plannedStart,
        plannedEnd: _plannedEnd,
        assignees: _people,
      ));
    } else {
      final hasNotes = _notes.text.trim().isNotEmpty;
      cubit.updateTask(
        widget.existing!.copyWith(
          title: title,
          notes: hasNotes ? _notes.text.trim() : null,
          clearNotes: !hasNotes,
          due: _due,
          clearDue: _due == null,
          plannedStart: _plannedStart,
          clearPlannedStart: _plannedStart == null,
          plannedEnd: _plannedEnd,
          clearPlannedEnd: _plannedEnd == null,
          assignees: _people,
        ),
      );
    }
    Navigator.of(context).pop();
  }

  void _delete(BuildContext context) {
    final existing = widget.existing;
    if (existing == null) return;
    final eventId = existing.calendarEventId ?? existing.sourceEventId;
    context.read<TaskCubit>().deleteTask(existing.id);
    if (eventId != null) {
      try {
        context.read<CalendarCubit>().clearTaskLink(eventId);
      } catch (_) {}
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Task deleted'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => context.read<UndoCubit>().undo(),
        ),
      ),
    );
    Navigator.of(context).pop();
  }
}

class _PlannedBlockField extends StatelessWidget {
  final DateTime? plannedStart;
  final DateTime? plannedEnd;
  final void Function(DateTime? start, DateTime? end) onChanged;

  const _PlannedBlockField({
    required this.plannedStart,
    required this.plannedEnd,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final start = plannedStart;
    final end = plannedEnd;
    final label = start != null && end != null
        ? '${DateFormat('EEE, MMM d').format(start)} · '
            '${TimeOfDay.fromDateTime(start).format(context)} – '
            '${TimeOfDay.fromDateTime(end).format(context)}'
        : 'No planned work block';
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Planned work block',
                  style: Theme.of(context).textTheme.labelLarge),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Pick planned block',
          icon: const Icon(Icons.schedule),
          onPressed: () async {
            final now = DateTime.now();
            final initialDate = start ?? now.add(const Duration(days: 1));
            final pickedDate = await showDatePicker(
              context: context,
              initialDate: initialDate,
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
            );
            if (pickedDate == null || !context.mounted) return;
            final initialStart =
                start != null ? TimeOfDay.fromDateTime(start) : const TimeOfDay(hour: 9, minute: 0);
            final pickedStart = await showTimePicker(
              context: context,
              initialTime: initialStart,
            );
            if (pickedStart == null || !context.mounted) return;
            final initialEnd = end != null
                ? TimeOfDay.fromDateTime(end)
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
            onChanged(blockStart, blockEnd);
          },
        ),
        if (start != null || end != null)
          IconButton(
            tooltip: 'Clear planned block',
            icon: const Icon(Icons.event_busy),
            onPressed: () => onChanged(null, null),
          ),
      ],
    );
  }
}
