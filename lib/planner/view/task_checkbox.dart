import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/calendar_cubit.dart';
import '../bloc/task_cubit.dart';
import '../model/planner_event.dart';
import '../model/task.dart';
import '../service/task_event_link.dart';

class TaskCheckbox extends StatefulWidget {
  final Task task;
  final double size;
  final Color? doneColor;

  const TaskCheckbox(
      {super.key, required this.task, this.size = 24, this.doneColor});

  @override
  State<TaskCheckbox> createState() => _TaskCheckboxState();
}

class _TaskCheckboxState extends State<TaskCheckbox> {
  DateTime? _lastTap;

  void _toggle() {
    TaskCubit tasks;
    CalendarCubit calendar;
    try {
      tasks = context.read<TaskCubit>();
      calendar = context.read<CalendarCubit>();
    } catch (_) {
      return;
    }
    if (widget.task.failed) {
      TaskEventLink.setTaskFailed(tasks, calendar, widget.task.id, false);
      return;
    }
    TaskEventLink.toggleTaskDone(tasks, calendar, widget.task.id);
  }

  void _markFailed() {
    TaskCubit tasks;
    CalendarCubit calendar;
    try {
      tasks = context.read<TaskCubit>();
      calendar = context.read<CalendarCubit>();
    } catch (_) {
      return;
    }
    if (widget.task.failed) return;
    TaskEventLink.setTaskFailed(tasks, calendar, widget.task.id, true);
    _lastTap = null;
  }

  void _onTap() {
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed) {
      _markFailed();
      return;
    }
    final now = DateTime.now();
    final last = _lastTap;
    if (last != null && now.difference(last).inMilliseconds < 400) {
      _markFailed();
      return;
    }
    _lastTap = now;
    _toggle();
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final theme = Theme.of(context);
    final IconData icon;
    final Color? color;
    final String stateLabel;
    if (task.done) {
      icon = Icons.check_box;
      color = widget.doneColor ?? theme.colorScheme.primary;
      stateLabel = 'Completed';
    } else if (task.failed) {
      icon = Icons.cancel;
      color = theme.colorScheme.error;
      stateLabel = 'Failed';
    } else {
      icon = Icons.check_box_outline_blank;
      color = null;
      stateLabel = 'Not done';
    }
    return Tooltip(
      message: '$stateLabel — tap to mark complete or unmark, '
          'double-tap or Ctrl+click to mark failed',
      child: InkWell(
        onTap: _onTap,
        onLongPress: _markFailed,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: widget.size, color: color),
        ),
      ),
    );
  }
}

class EventTaskCheckbox extends StatefulWidget {
  final PlannerEvent event;
  final double size;
  final Color? doneColor;

  const EventTaskCheckbox(
      {super.key, required this.event, this.size = 24, this.doneColor});

  @override
  State<EventTaskCheckbox> createState() => _EventTaskCheckboxState();
}

class _EventTaskCheckboxState extends State<EventTaskCheckbox> {
  DateTime? _lastTap;

  void _toggleFallback() {
    CalendarCubit calendar;
    TaskCubit tasks;
    try {
      calendar = context.read<CalendarCubit>();
      tasks = context.read<TaskCubit>();
    } catch (_) {
      return;
    }
    if (widget.event.failed) {
      TaskEventLink.setEventFailed(calendar, tasks, widget.event.id, false);
      return;
    }
    TaskEventLink.toggleEventDone(calendar, tasks, widget.event.id);
  }

  void _failFallback() {
    CalendarCubit calendar;
    TaskCubit tasks;
    try {
      calendar = context.read<CalendarCubit>();
      tasks = context.read<TaskCubit>();
    } catch (_) {
      return;
    }
    if (widget.event.failed) return;
    TaskEventLink.setEventFailed(calendar, tasks, widget.event.id, true);
    _lastTap = null;
  }

  void _onTapFallback() {
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed) {
      _failFallback();
      return;
    }
    final now = DateTime.now();
    final last = _lastTap;
    if (last != null && now.difference(last).inMilliseconds < 400) {
      _failFallback();
      return;
    }
    _lastTap = now;
    _toggleFallback();
  }

  @override
  Widget build(BuildContext context) {
    Task? backing;
    try {
      final tasks = context.watch<TaskCubit>().state;
      for (final t in tasks) {
        if (t.calendarEventId == widget.event.id ||
            t.sourceEventId == widget.event.id ||
            t.id == widget.event.taskId) {
          backing = t;
          break;
        }
      }
    } catch (_) {}
    if (backing != null) {
      return TaskCheckbox(
          task: backing, size: widget.size, doneColor: widget.doneColor);
    }
    final event = widget.event;
    try {
      final live = context
          .watch<CalendarCubit>()
          .byId(event.id) ??
          event;
      return _FallbackBox(
        done: live.done,
        failed: live.failed,
        size: widget.size,
        onTap: _onTapFallback,
        onLongPress: _failFallback,
      );
    } catch (_) {
      return _FallbackBox(
        done: event.done,
        failed: event.failed,
        size: widget.size,
        onTap: _onTapFallback,
        onLongPress: _failFallback,
      );
    }
  }
}

class _FallbackBox extends StatelessWidget {
  final bool done;
  final bool failed;
  final double size;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _FallbackBox({
    required this.done,
    required this.failed,
    required this.size,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final IconData icon;
    final Color? color;
    final String stateLabel;
    if (done) {
      icon = Icons.check_box;
      color = theme.colorScheme.primary;
      stateLabel = 'Completed';
    } else if (failed) {
      icon = Icons.cancel;
      color = theme.colorScheme.error;
      stateLabel = 'Failed';
    } else {
      icon = Icons.check_box_outline_blank;
      color = null;
      stateLabel = 'Not done';
    }
    return Tooltip(
      message: '$stateLabel — tap to mark complete or unmark, '
          'double-tap or Ctrl+click to mark failed',
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: size, color: color),
        ),
      ),
    );
  }
}
