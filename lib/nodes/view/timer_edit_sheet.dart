import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/service/event_tracking.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_sync.dart';
import '../bloc/node_cubit.dart';
import 'goal_picker.dart';

/// Toggl-style correction for a running or recorded timer.
///
/// - **Running**: edits the start only; the timer keeps recording and the
///   elapsed preview updates live. Fixes a late press or a gap left by a
///   rebuild without losing the session.
/// - **Stopped**: edits the recorded start/end interval. With no recorded
///   time yet it acts as a manual entry (Toggl's manual mode), prefilled
///   from the planned block when there is one.
///
/// Dates and times use the plain pickers (not the day-scoped dial): a
/// corrected start can be any earlier moment, including a previous day.
Future<void> showEditNodeTimerSheet(
  BuildContext context, {
  required String nodeId,
}) async {
  String title = 'Timer';
  bool running = false;
  DateTime initialStart = DateTime.now();
  DateTime initialEnd = DateTime.now().add(const Duration(hours: 1));
  try {
    final node = context.read<NodeCubit>().byId(nodeId);
    if (node == null) return;
    title = node.title;
    running = node.isTracking;
    initialStart = running && node.timerStartedAt != null
        ? node.timerStartedAt!
        : (node.actualStart ??
            node.schedule?.start ??
            node.schedule?.due ??
            DateTime.now());
    initialEnd = node.actualEnd ??
        node.schedule?.end ??
        initialStart.add(const Duration(hours: 1));
  } catch (_) {
    return;
  }
  if (!context.mounted) return;
  return showTimerEditSheet(
    context,
    recordTitle: title,
    running: running,
    hasReported: () {
      try {
        return context.read<NodeCubit>().byId(nodeId)?.hasReported ?? false;
      } catch (_) {
        return false;
      }
    }(),
    initialStart: initialStart,
    initialEnd: initialEnd,
    onSaveStart: (start) {
      try {
        context.read<NodeCubit>().setTimerStart(nodeId, start);
      } catch (_) {}
    },
    onSaveRange: (start, end) {
      try {
        NodeEventSync.setNodeReported(
          context.read<NodeCubit>(),
          context.read<CalendarCubit>(),
          nodeId,
          start,
          end,
        );
      } catch (_) {}
    },
    onReassignGoal: (goalId) {
      try {
        context.read<NodeCubit>().reassignChunk(nodeId, goalId);
      } catch (_) {}
    },
  );
}

/// Event-side twin of [showEditNodeTimerSheet]. Plain (node-less) events
/// drive the event timer; node-backed events drive the node timer through
/// the node sheet instead.
Future<void> showEditEventTimerSheet(
  BuildContext context, {
  required String eventId,
}) async {
  String title = 'Timer';
  bool running = false;
  bool hasReported = false;
  DateTime initialStart = DateTime.now();
  DateTime initialEnd = DateTime.now().add(const Duration(hours: 1));
  try {
    final event = context.read<CalendarCubit>().byId(eventId);
    if (event == null) return;
    title = event.subject;
    running = event.isTracking;
    hasReported = event.hasReported;
    initialStart = running && event.timerStartedAt != null
        ? event.timerStartedAt!
        : (event.actualStart ?? event.start);
    initialEnd = event.actualEnd ?? event.end;
    if (!initialEnd.isAfter(initialStart)) {
      initialEnd = initialStart.add(const Duration(hours: 1));
    }
  } catch (_) {
    return;
  }
  if (!context.mounted) return;
  return showTimerEditSheet(
    context,
    recordTitle: title,
    running: running,
    hasReported: hasReported,
    initialStart: initialStart,
    initialEnd: initialEnd,
    onSaveStart: (start) {
      try {
        context.read<CalendarCubit>().setTimerStart(eventId, start);
      } catch (_) {}
    },
    onSaveRange: (start, end) {
      try {
        context.read<CalendarCubit>().setReported(eventId, start, end);
      } catch (_) {}
    },
  );
}

/// Generic sheet behind the node/event entry points above. [onSaveStart]
/// runs in the running mode, [onSaveRange] in the stopped/manual mode.
Future<void> showTimerEditSheet(
  BuildContext context, {
  required String recordTitle,
  required bool running,
  required bool hasReported,
  required DateTime initialStart,
  required DateTime initialEnd,
  required ValueChanged<DateTime> onSaveStart,
  required void Function(DateTime start, DateTime end) onSaveRange,
  ValueChanged<String>? onReassignGoal,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: _TimerEditSheet(
        recordTitle: recordTitle,
        running: running,
        hasReported: hasReported,
        initialStart: initialStart,
        initialEnd: initialEnd,
        onSaveStart: onSaveStart,
        onSaveRange: onSaveRange,
        onReassignGoal: onReassignGoal,
      ),
    ),
  );
}

class _TimerEditSheet extends StatefulWidget {
  final String recordTitle;
  final bool running;
  final bool hasReported;
  final DateTime initialStart;
  final DateTime initialEnd;
  final ValueChanged<DateTime> onSaveStart;
  final void Function(DateTime start, DateTime end) onSaveRange;
  final ValueChanged<String>? onReassignGoal;

  const _TimerEditSheet({
    required this.recordTitle,
    required this.running,
    required this.hasReported,
    required this.initialStart,
    required this.initialEnd,
    required this.onSaveStart,
    required this.onSaveRange,
    this.onReassignGoal,
  });

  @override
  State<_TimerEditSheet> createState() => _TimerEditSheetState();
}

class _TimerEditSheetState extends State<_TimerEditSheet> {
  late DateTime _startDay;
  late TimeOfDay _start;
  late DateTime _endDay;
  late TimeOfDay _end;
  Timer? _ticker;

  DateTime get _startDateTime => DateTime(
        _startDay.year,
        _startDay.month,
        _startDay.day,
        _start.hour,
        _start.minute,
      );

  DateTime get _endDateTime => DateTime(
        _endDay.year,
        _endDay.month,
        _endDay.day,
        _end.hour,
        _end.minute,
      );

  @override
  void initState() {
    super.initState();
    final s = widget.initialStart;
    _startDay = DateTime(s.year, s.month, s.day);
    _start = TimeOfDay.fromDateTime(s);
    var e = widget.initialEnd;
    if (!e.isAfter(s)) e = s.add(const Duration(hours: 1));
    _endDay = DateTime(e.year, e.month, e.day);
    _end = TimeOfDay.fromDateTime(e);
    // Live elapsed while running: moving the start visibly moves the
    // duration, which is the whole point of the correction.
    if (widget.running) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateFormat = DateFormat('EEE, MMM d, yyyy');
    final running = widget.running;
    final startDt = _startDateTime;
    final now = DateTime.now();
    final elapsed =
        now.isAfter(startDt) ? now.difference(startDt) : Duration.zero;
    var endDt = _endDateTime;
    var bumped = false;
    if (!endDt.isAfter(startDt)) {
      endDt = startDt.add(const Duration(minutes: 1));
      bumped = true;
    }
    final rangeMinutes = endDt.difference(startDt).inMinutes;
    final rangeLabel = rangeMinutes < 60
        ? '${rangeMinutes}m'
        : '${rangeMinutes ~/ 60}h${rangeMinutes % 60 == 0 ? '' : ' ${rangeMinutes % 60}m'}';
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              running ? 'Edit start time' : 'Edit recorded time',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              widget.recordTitle,
              style: theme.textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              running
                  ? 'Recording ${formatStopwatch(elapsed)} — the timer keeps '
                      'running; only the start moves.'
                  : widget.hasReported
                      ? 'Recorded $rangeLabel'
                      : 'No recorded time yet — this adds one ($rangeLabel).',
              style: theme.textTheme.bodySmall?.copyWith(
                color: running ? theme.colorScheme.primary : null,
                fontWeight: running ? FontWeight.w600 : null,
              ),
            ),
            const SizedBox(height: 12),
            _DateRow(
              label: 'Start date',
              value: dateFormat.format(_startDay),
              onPick: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _startDay,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) setState(() => _startDay = picked);
              },
            ),
            const SizedBox(height: 8),
            _TimeRow(
              label: 'Start time',
              time: _start,
              onPick: () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: _start,
                );
                if (picked != null) setState(() => _start = picked);
              },
            ),
            if (!running) ...[
              const SizedBox(height: 8),
              _DateRow(
                label: 'End date',
                value: dateFormat.format(_endDay),
                onPick: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _endDay,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) setState(() => _endDay = picked);
                },
              ),
              const SizedBox(height: 8),
              _TimeRow(
                label: 'End time',
                time: _end,
                onPick: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: _end,
                  );
                  if (picked != null) setState(() => _end = picked);
                },
              ),
              if (bumped)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'End is not after start — saves as 1 minute.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
            if (running && startDt.isAfter(now))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Start is in the future — saves as now.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            if (widget.onReassignGoal != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final picked = await showGoalPicker(
                      context,
                      title: 'Move chunk to goal',
                      excludeNodeId: null,
                    );
                    if (picked != null) {
                      widget.onReassignGoal!(picked.id);
                      if (context.mounted) Navigator.of(context).pop();
                    }
                  },
                  icon: const Icon(Icons.flag_outlined, size: 18),
                  label: const Text('Move to another goal'),
                ),
              ),
            ],
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
                    if (running) {
                      widget.onSaveStart(startDt);
                    } else {
                      widget.onSaveRange(startDt, endDt);
                    }
                    Navigator.of(context).pop();
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
}

class _DateRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onPick;

  const _DateRow({
    required this.label,
    required this.value,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPick,
      child: InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Text(value),
      ),
    );
  }
}

class _TimeRow extends StatelessWidget {
  final String label;
  final TimeOfDay time;
  final VoidCallback onPick;

  const _TimeRow({
    required this.label,
    required this.time,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPick,
      child: InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Text(time.format(context)),
      ),
    );
  }
}
