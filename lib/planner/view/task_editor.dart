import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../common/undo/undo_cubit.dart';
import '../bloc/calendar_cubit.dart';
import '../bloc/task_cubit.dart';
import '../model/task.dart';

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

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.existing?.title ?? '');
    _notes = TextEditingController(text: widget.existing?.notes ?? '');
    _due = widget.existing?.due;
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
