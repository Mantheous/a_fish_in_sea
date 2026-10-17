import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/model/node.dart';
import '../../nodes/service/node_event_link.dart';
import '../../nodes/view/node_finish_sheet.dart';
import '../../nodes/view/timer_edit_sheet.dart';
import '../bloc/calendar_cubit.dart';
import '../bloc/settings_cubit.dart';
import '../model/event_reschedule.dart';
import '../model/planner_event.dart';
import '../../reporting/view/time_range_dial.dart';

/// Time-tracking sections for the event detail/editor sheets.
///
/// Split out of `event_editor.dart` (which is ~3400 lines) so the
/// single-active-timer fix lives in a small, testable file.
class TaskTimeSection extends StatelessWidget {
  final PlannerEvent event;

  const TaskTimeSection({super.key, required this.event});

  @override
  Widget build(BuildContext context) {
    Node? node;
    try {
      for (final n in context.watch<NodeCubit>().state) {
        if (n.calendarEventId == event.id ||
            n.sourceEventId == event.id ||
            n.id == event.taskId) {
          node = n;
          break;
        }
      }
    } catch (_) {}
    if (node == null) {
      if (event.allDay) return const SizedBox.shrink();
      return TimeReportSection(event: event);
    }
    final failed = node.status == NodeStatus.failed;
    final theme = Theme.of(context);
    final timeFormatter = DateFormat('h:mm a');
    final plannedStart = node.schedule?.start ?? event.start;
    final plannedEnd = node.schedule?.end ?? event.end;
    final plannedMin = plannedEnd.isAfter(plannedStart)
        ? plannedEnd.difference(plannedStart).inMinutes
        : 0;
    final reported = node.reportedDuration;
    final lines = <String>[
      'Planned ${timeFormatter.format(plannedStart)} – '
          '${timeFormatter.format(plannedEnd)} (${plannedMin}m)',
      if (node.isTracking && node.timerStartedAt != null)
        'Recording since ${timeFormatter.format(node.timerStartedAt!)}',
      if (reported != null &&
          node.actualStart != null &&
          node.actualEnd != null)
        'Reported ${timeFormatter.format(node.actualStart!)} – '
            '${timeFormatter.format(node.actualEnd!)} (${reported.inMinutes}m)',
      if (failed) 'Marked as failed',
    ];
    final nodeId = node.id;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Time tracking', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          for (final line in lines)
            Text(
              line,
              style: theme.textTheme.bodySmall?.copyWith(
                color: line.startsWith('Marked as failed')
                    ? theme.colorScheme.error
                    : null,
                fontWeight: line.startsWith('Recording') ||
                        line.startsWith('Marked as failed')
                    ? FontWeight.w600
                    : null,
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (node.isTracking)
                FilledButton.icon(
                  onPressed: () => stopNodeAndFinish(context, nodeId),
                  icon: const Icon(Icons.stop, size: 16),
                  label: const Text('Stop'),
                )
              else
                OutlinedButton.icon(
                  onPressed: node.isDone
                      ? null
                      : () {
                          try {
                            NodeEventLink.startNodeTracking(
                              context.read<NodeCubit>(),
                              context.read<CalendarCubit>(),
                              nodeId,
                            );
                          } catch (_) {}
                        },
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('Start'),
                ),
              if (node.isTracking)
                TextButton.icon(
                  onPressed: () => showEditNodeTimerSheet(
                    context,
                    nodeId: nodeId,
                  ),
                  icon: const Icon(Icons.edit, size: 16),
                  label: const Text('Edit start'),
                ),
              OutlinedButton(
                onPressed: () {
                  try {
                    NodeEventLink.setNodeFailed(
                      context.read<NodeCubit>(),
                      context.read<CalendarCubit>(),
                      nodeId,
                      !failed,
                    );
                  } catch (_) {}
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor:
                      failed ? null : theme.colorScheme.error,
                ),
                child: Text(failed ? 'Unfail' : 'Mark failed'),
              ),
              TextButton(
                onPressed: () =>
                    showFollowUpScheduler(context, nodeId: nodeId),
                child: const Text('Follow-up'),
              ),
              if (node.hasReported && !node.isTracking)
                TextButton(
                  onPressed: () {
                    try {
                      context.read<NodeCubit>().clearReported(nodeId);
                    } catch (_) {}
                  },
                  child: const Text('Clear reported'),
                ),
              if (node.hasReported && !node.isTracking)
                TextButton.icon(
                  onPressed: () => showEditNodeTimerSheet(
                    context,
                    nodeId: nodeId,
                  ),
                  icon: const Icon(Icons.tune, size: 16),
                  label: const Text('Adjust'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class TimeReportSection extends StatelessWidget {
  final PlannerEvent event;

  const TimeReportSection({super.key, required this.event});

  void _toggle(BuildContext context, String eventId, bool isTracking) {
    try {
      final nodes = context.read<NodeCubit>();
      final calendar = context.read<CalendarCubit>();
      if (isTracking) {
        NodeEventLink.stopEventTrackingAligned(nodes, calendar, eventId);
      } else {
        // Single active timer across both stores (Toggl-style): starting
        // this plain event first saves + stops any running node timer,
        // so two timers can never record at once.
        NodeEventLink.startEventTracking(nodes, calendar, eventId);
      }
      return;
    } catch (_) {}
    // Standalone contexts without a NodeCubit keep calendar-only behaviour.
    try {
      final calendar = context.read<CalendarCubit>();
      if (isTracking) {
        calendar.stopTracking(eventId);
      } else {
        calendar.startTracking(eventId);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Resolve the live event so Start/Stop reflect the current timer even
    // when the parent sheet passes a stale snapshot.
    PlannerEvent live = event;
    try {
      live = context.watch<CalendarCubit>().byId(event.id) ?? event;
    } catch (_) {}
    final timeFormatter = DateFormat('h:mm a');
    final plannedMin = live.plannedDuration.inMinutes;
    final reported = live.reportedDuration;
    final lines = <String>[
      'Planned ${timeFormatter.format(live.start)} – '
          '${timeFormatter.format(live.end)} (${plannedMin}m)',
      if (live.isTracking && live.timerStartedAt != null)
        'Recording since ${timeFormatter.format(live.timerStartedAt!)}',
      if (reported != null &&
          live.actualStart != null &&
          live.actualEnd != null)
        'Reported ${timeFormatter.format(live.actualStart!)} – '
            '${timeFormatter.format(live.actualEnd!)} (${reported.inMinutes}m)',
      if (live.failed) 'Marked as failed',
    ];
    final eventId = live.id;
    final isTracking = live.isTracking;
    final failed = live.failed;
    final hasReported = live.hasReported;
    final isTask = live.isTask;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Time tracking', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          for (final line in lines)
            Text(
              line,
              style: theme.textTheme.bodySmall?.copyWith(
                color: line.startsWith('Marked as failed')
                    ? theme.colorScheme.error
                    : null,
                fontWeight: line.startsWith('Recording') ||
                        line.startsWith('Marked as failed')
                    ? FontWeight.w600
                    : null,
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (isTracking)
                FilledButton.icon(
                  onPressed: () => _toggle(context, eventId, true),
                  icon: const Icon(Icons.stop, size: 16),
                  label: const Text('Stop'),
                )
              else
                OutlinedButton.icon(
                  onPressed: () => _toggle(context, eventId, false),
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('Start'),
                ),
              if (isTracking)
                TextButton.icon(
                  onPressed: () => showEditEventTimerSheet(
                    context,
                    eventId: eventId,
                  ),
                  icon: const Icon(Icons.edit, size: 16),
                  label: const Text('Edit start'),
                ),
              // "Mark failed" only makes sense for task-events; plain
              // calendar events just record time.
              if (isTask)
                OutlinedButton(
                  onPressed: () => context
                      .read<CalendarCubit>()
                      .setFailed(eventId, !failed),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: failed
                        ? null
                        : theme.colorScheme.error,
                  ),
                  child: Text(failed ? 'Unfail' : 'Mark failed'),
                ),
              if (hasReported && !isTracking)
                TextButton(
                  onPressed: () => context
                      .read<CalendarCubit>()
                      .clearReported(eventId),
                  child: const Text('Clear reported'),
                ),
              if (hasReported && !isTracking)
                TextButton.icon(
                  onPressed: () =>
                      showAdjustTimerSheet(context, eventId: eventId),
                  icon: const Icon(Icons.tune, size: 16),
                  label: const Text('Adjust'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet with the circular [TimeRangeDial] for correcting a
/// timer-logged interval (`actualStart`/`actualEnd`) on a calendar event.
/// Saves once via [CalendarCubit.updateEvent], so dragging the handles is
/// a single undoable change.
Future<void> showAdjustTimerSheet(
  BuildContext context, {
  required String eventId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: _AdjustTimerSheet(eventId: eventId),
    ),
  );
}

class _AdjustTimerSheet extends StatefulWidget {
  final String eventId;

  const _AdjustTimerSheet({required this.eventId});

  @override
  State<_AdjustTimerSheet> createState() => _AdjustTimerSheetState();
}

class _AdjustTimerSheetState extends State<_AdjustTimerSheet> {
  late DateTime _day;
  late int _dayOffset;
  late TimeOfDay _start;
  late TimeOfDay _end;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    PlannerEvent? live;
    try {
      live = context.read<CalendarCubit>().byId(widget.eventId);
    } catch (_) {}
    final actualStart = live?.actualStart ?? live?.start;
    final actualEnd = live?.actualEnd ?? live?.end;
    if (actualStart == null || actualEnd == null) {
      final now = DateTime.now();
      _day = DateTime(now.year, now.month, now.day);
      _dayOffset = 0;
      _start = TimeOfDay.fromDateTime(now);
      _end = TimeOfDay.fromDateTime(now.add(const Duration(hours: 1)));
    } else {
      _day = DateTime(
        actualStart.year,
        actualStart.month,
        actualStart.day,
      );
      final endDay = DateTime(actualEnd.year, actualEnd.month, actualEnd.day);
      _dayOffset = endDay.difference(_day).inDays.clamp(0, 1);
      _start = TimeOfDay.fromDateTime(actualStart);
      _end = TimeOfDay.fromDateTime(actualEnd);
    }
    _ready = true;
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const SizedBox.shrink();
    var snap = 5;
    try {
      snap = context.read<SettingsCubit>().state.snapMinutes;
    } catch (_) {}
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Adjust reported time',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Center(
              child: TimeRangeDial(
                start: _start,
                end: _end,
                snapMinutes: snap,
                onStartChanged: (v) => setState(() => _start = v),
                onEndChanged: (v) => setState(() => _end = v),
              ),
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
                    CalendarCubit calendar;
                    try {
                      calendar = context.read<CalendarCubit>();
                    } catch (_) {
                      Navigator.of(context).pop();
                      return;
                    }
                    final live = calendar.byId(widget.eventId);
                    if (live == null || !live.hasReported) {
                      Navigator.of(context).pop();
                      return;
                    }
                    final start = DateTime(_day.year, _day.month, _day.day,
                        _start.hour, _start.minute);
                    var end = DateTime(_day.year, _day.month, _day.day,
                            _end.hour, _end.minute)
                        .add(Duration(days: _dayOffset));
                    if (!end.isAfter(start)) {
                      end = start.add(minEventDuration);
                    }
                    calendar.updateEvent(
                      live.copyWith(actualStart: start, actualEnd: end),
                    );
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
