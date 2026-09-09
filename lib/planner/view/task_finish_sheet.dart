import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../bloc/calendar_cubit.dart';
import '../bloc/task_cubit.dart';
import '../model/task.dart';
import '../service/task_event_link.dart';

Future<void> stopTaskAndFinish(BuildContext context, String taskId) async {
  Task? task;
  try {
    task = context.read<TaskCubit>().byId(taskId);
  } catch (_) {
    return;
  }
  if (task == null) return;
  if (task.isTracking) {
    try {
      context.read<TaskCubit>().stopTracking(taskId);
    } catch (_) {}
  }
  if (!context.mounted) return;
  await showTaskFinishSheet(context, taskId: taskId);
}

Future<void> showTaskFinishSheet(
  BuildContext context, {
  required String taskId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => _FinishSheet(taskId: taskId),
  );
}

Future<void> showFollowUpScheduler(
  BuildContext context, {
  required String taskId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: _FollowUpSheet(taskId: taskId),
    ),
  );
}

class _FinishSheet extends StatelessWidget {
  final String taskId;

  const _FinishSheet({required this.taskId});

  @override
  Widget build(BuildContext context) {
    Task? task;
    try {
      task = context.watch<TaskCubit>().byId(taskId);
    } catch (_) {}
    if (task == null) {
      return const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('This task was deleted.'),
        ),
      );
    }
    final theme = Theme.of(context);
    final timeFormat = DateFormat('h:mm a');
    final reported = task.reportedDuration;
    final reportedLine = reported != null &&
            task.actualStart != null &&
            task.actualEnd != null
        ? 'Recorded ${timeFormat.format(task.actualStart!)} – '
            '${timeFormat.format(task.actualEnd!)} (${reported.inMinutes}m)'
        : 'Recording saved.';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Work session saved',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(task.title, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 4),
            Text(reportedLine, style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                try {
                  final tasks = context.read<TaskCubit>();
                  final current = tasks.byId(taskId);
                  if (current != null && !current.done) {
                    TaskEventLink.toggleTaskDone(
                      tasks,
                      context.read<CalendarCubit>(),
                      taskId,
                    );
                  }
                } catch (_) {}
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Mark complete'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                try {
                  TaskEventLink.setTaskFailed(
                    context.read<TaskCubit>(),
                    context.read<CalendarCubit>(),
                    taskId,
                    true,
                  );
                } catch (_) {}
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.cancel_outlined, size: 18),
              label: const Text('Mark failed'),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                showFollowUpScheduler(context, taskId: taskId);
              },
              icon: const Icon(Icons.schedule, size: 18),
              label: const Text('Schedule follow-up'),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FollowUpSheet extends StatefulWidget {
  final String taskId;

  const _FollowUpSheet({required this.taskId});

  @override
  State<_FollowUpSheet> createState() => _FollowUpSheetState();
}

class _FollowUpSheetState extends State<_FollowUpSheet> {
  late DateTime _date;
  late TimeOfDay _start;
  late TimeOfDay _end;

  @override
  void initState() {
    super.initState();
    DateTime base = DateTime.now().add(const Duration(days: 1));
    TimeOfDay start = const TimeOfDay(hour: 9, minute: 0);
    try {
      final task = context.read<TaskCubit>().byId(widget.taskId);
      final planned = task?.plannedStart;
      if (planned != null) {
        base = planned.add(const Duration(days: 1));
        start = TimeOfDay.fromDateTime(planned);
      } else if (task?.due != null) {
        base = task!.due!;
        start = TimeOfDay.fromDateTime(task.due!);
      }
    } catch (_) {}
    _date = DateTime(base.year, base.month, base.day);
    _start = start;
    final endMinutes = _start.hour * 60 + _start.minute + 60;
    _end = TimeOfDay(hour: (endMinutes ~/ 60) % 24, minute: endMinutes % 60);
  }

  DateTime get _startDateTime => DateTime(
        _date.year,
        _date.month,
        _date.day,
        _start.hour,
        _start.minute,
      );

  DateTime get _endDateTime {
    var end = DateTime(
      _date.year,
      _date.month,
      _date.day,
      _end.hour,
      _end.minute,
    );
    if (!end.isAfter(_startDateTime)) {
      end = _startDateTime.add(const Duration(hours: 1));
    }
    return end;
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('EEE, MMM d, yyyy');
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Schedule follow-up',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Sets the next planned work block on this task.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) setState(() => _date = picked);
              },
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Date'),
                child: Text(dateFormat.format(_date)),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: _start,
                      );
                      if (picked == null) return;
                      setState(() {
                        _start = picked;
                        if (_toMinutes(_end) <= _toMinutes(_start)) {
                          final endMinutes =
                              _start.hour * 60 + _start.minute + 60;
                          _end = TimeOfDay(
                            hour: (endMinutes ~/ 60) % 24,
                            minute: endMinutes % 60,
                          );
                        }
                      });
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: 'Start'),
                      child: Text(_start.format(context)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: _end,
                      );
                      if (picked != null) setState(() => _end = picked);
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: 'End'),
                      child: Text(_end.format(context)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    try {
                      context.read<TaskCubit>().setPlannedInterval(
                            widget.taskId,
                            _startDateTime,
                            _endDateTime,
                          );
                    } catch (_) {}
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Follow-up scheduled for ${dateFormat.format(_date)} '
                          'at ${_start.format(context)}',
                        ),
                      ),
                    );
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static int _toMinutes(TimeOfDay time) => time.hour * 60 + time.minute;
}
