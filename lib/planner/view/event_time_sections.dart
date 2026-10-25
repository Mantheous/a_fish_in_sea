import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/model/node.dart';
import '../../nodes/service/node_event_link.dart';
import '../../nodes/service/node_event_sync.dart';
import '../../nodes/view/node_finish_sheet.dart';
import '../../nodes/view/timer_edit_sheet.dart';
import '../bloc/calendar_cubit.dart';
import '../model/planner_event.dart';

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
    final sessions = node.recordedSessions;
    final lines = <String>[
      'Planned ${timeFormatter.format(plannedStart)} – '
          '${timeFormatter.format(plannedEnd)} (${plannedMin}m)',
      if (node.isTracking && node.timerStartedAt != null)
        'Recording since ${timeFormatter.format(node.timerStartedAt!)}',
      if (reported != null && sessions.isNotEmpty)
        sessions.length > 1
            ? 'Reported ${sessions.length} sessions · ${reported.inMinutes}m'
            : 'Reported ${timeFormatter.format(sessions.single.start)} – '
                  '${timeFormatter.format(sessions.single.end)} '
                  '(${reported.inMinutes}m)',
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
                fontWeight:
                    line.startsWith('Recording') ||
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
                  onPressed: () =>
                      showEditNodeTimerSheet(context, nodeId: nodeId),
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
                  foregroundColor: failed ? null : theme.colorScheme.error,
                ),
                child: Text(failed ? 'Unfail' : 'Mark failed'),
              ),
              TextButton(
                onPressed: () => showFollowUpScheduler(context, nodeId: nodeId),
                child: const Text('Follow-up'),
              ),
              if (node.hasReported && !node.isTracking)
                TextButton(
                  onPressed: () {
                    try {
                      NodeEventSync.clearNodeReported(
                        context.read<NodeCubit>(),
                        context.read<CalendarCubit>(),
                        nodeId,
                      );
                    } catch (_) {}
                  },
                  child: const Text('Clear reported'),
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
    final sessions = live.recordedSessions;
    final lines = <String>[
      'Planned ${timeFormatter.format(live.start)} – '
          '${timeFormatter.format(live.end)} (${plannedMin}m)',
      if (live.isTracking && live.timerStartedAt != null)
        'Recording since ${timeFormatter.format(live.timerStartedAt!)}',
      if (reported != null && sessions.isNotEmpty)
        sessions.length > 1
            ? 'Reported ${sessions.length} sessions · ${reported.inMinutes}m'
            : 'Reported ${timeFormatter.format(sessions.single.start)} – '
                  '${timeFormatter.format(sessions.single.end)} '
                  '(${reported.inMinutes}m)',
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
                fontWeight:
                    line.startsWith('Recording') ||
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
                  onPressed: () =>
                      showEditEventTimerSheet(context, eventId: eventId),
                  icon: const Icon(Icons.edit, size: 16),
                  label: const Text('Edit start'),
                ),
              // "Mark failed" only makes sense for task-events; plain
              // calendar events just record time.
              if (isTask)
                OutlinedButton(
                  onPressed: () =>
                      context.read<CalendarCubit>().setFailed(eventId, !failed),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: failed ? null : theme.colorScheme.error,
                  ),
                  child: Text(failed ? 'Unfail' : 'Mark failed'),
                ),
              if (hasReported && !isTracking)
                TextButton(
                  onPressed: () =>
                      context.read<CalendarCubit>().clearReported(eventId),
                  child: const Text('Clear reported'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
