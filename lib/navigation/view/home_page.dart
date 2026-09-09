import 'dart:async';

import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/navigation/view/app_drawer.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/task_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/model/task.dart';
import 'package:a_fish_in_sea/planner/service/event_tracking.dart';
import 'package:a_fish_in_sea/planner/service/task_tracking.dart';
import 'package:a_fish_in_sea/planner/view/task_checkbox.dart';
import 'package:a_fish_in_sea/planner/view/task_editor.dart';
import 'package:a_fish_in_sea/planner/view/task_finish_sheet.dart';
import 'package:a_fish_in_sea/reporting/bloc/tracking_cubit.dart';
import 'package:a_fish_in_sea/reporting/service/location_service.dart';
import 'package:a_fish_in_sea/reporting/view/day_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final feedCubit = context.read<FeedCubit>();
      feedCubit.startAutoResync();
      feedCubit.syncAll();
    });
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final feedCubit = context.watch<FeedCubit>();
    final todayEvents = feedCubit.visibleEvents(
      context.watch<CalendarCubit>().eventsOnDay(today),
    );
    final dueTasks = feedCubit.visibleTasks(
      context.watch<TaskCubit>().overdueAndToday,
    );
    final weekTasks = feedCubit.visibleTasks(
      context.watch<TaskCubit>().dueThisWeek,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      drawer: const AppDrawer(),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showTaskEditor(context),
        child: const Icon(Icons.add),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const _TimeTrackingCard(),
          const _TrackingCard(),
          _SectionCard(
            title: 'Tasks due today',
            onMore: () =>
                context.read<NavigationCubit>().setPage(PlannerPage.tasks),
            child: dueTasks.isEmpty
                ? const _EmptyLine('Nothing due today')
                : Column(
                    children: [
                      for (final task in dueTasks.take(5)) _TaskLine(task: task),
                    ],
                  ),
          ),
          _SectionCard(
            title: 'Today',
            onMore: () =>
                context.read<NavigationCubit>().setPage(PlannerPage.calendar),
            child: todayEvents.isEmpty
                ? const _EmptyLine('No events today')
                : Column(
                    children: [
                      for (final event in todayEvents)
                        _EventLine(event: event),
                    ],
                  ),
          ),
          _SectionCard(
            title: 'Tasks due this week',
            onMore: () =>
                context.read<NavigationCubit>().setPage(PlannerPage.tasks),
            child: weekTasks.isEmpty
                ? const _EmptyLine('No tasks due this week')
                : Column(
                    children: [
                      for (final task in weekTasks)
                        _AssignmentLine(task: task),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final VoidCallback onMore;
  final Widget child;

  const _SectionCard({
    required this.title,
    required this.onMore,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: Theme.of(context).textTheme.titleMedium),
                ),
                TextButton(
                  onPressed: onMore,
                  child: const Text('See all'),
                ),
              ],
            ),
            child,
          ],
        ),
      ),
    );
  }
}

class _EmptyLine extends StatelessWidget {
  final String text;

  const _EmptyLine(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

class _TaskLine extends StatelessWidget {
  final Task task;

  const _TaskLine({required this.task});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final live = context.watch<TaskCubit>().byId(task.id) ?? task;
    final status = live.failed
        ? 'Failed'
        : live.isOverdue
            ? 'Overdue'
            : 'Due today';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: TaskCheckbox(task: live),
      title: Text(
        live.title,
        style: live.done || live.failed
            ? TextStyle(
                decoration: TextDecoration.lineThrough,
                color: live.failed ? theme.colorScheme.error : null,
              )
            : null,
      ),
      subtitle: Text(
        status,
        style: theme.textTheme.labelSmall?.copyWith(
          color: live.isOverdue || live.failed
              ? theme.colorScheme.error
              : null,
        ),
      ),
    );
  }
}

class _EventLine extends StatelessWidget {
  final PlannerEvent event;

  const _EventLine({required this.event});

  @override
  Widget build(BuildContext context) {
    final feed = event.feedId == null
        ? null
        : context.read<FeedCubit>().byId(event.feedId!);
    final timeFormatter = DateFormat('h:mm a');
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: feed?.color ?? Theme.of(context).colorScheme.primary,
          shape: BoxShape.circle,
        ),
      ),
      title: Text(
        event.subject,
        style: event.isTask && event.done
            ? const TextStyle(decoration: TextDecoration.lineThrough)
            : null,
      ),
      subtitle: Text(
        event.allDay ? 'All day' : timeFormatter.format(event.start),
        style: Theme.of(context).textTheme.labelSmall,
      ),
      trailing: event.isTask
          ? Icon(
              event.done ? Icons.check_circle : Icons.check_circle_outline,
              size: 20,
            )
          : null,
    );
  }
}

class _AssignmentLine extends StatelessWidget {
  final Task task;

  const _AssignmentLine({required this.task});

  @override
  Widget build(BuildContext context) {
    final feedCubit = context.read<FeedCubit>();
    final Feed? feed = task.classId == null
        ? null
        : feedCubit.byId(task.classId!);
    final formatter = DateFormat('EEE, MMM d');
    final label = task.classLabel ?? feed?.name ?? 'Task';
    final live = context.watch<TaskCubit>().byId(task.id) ?? task;
    final dueLabel = live.due == null
        ? label
        : '$label · due ${formatter.format(live.due!)}';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: TaskCheckbox(task: live),
      title: Text(
        live.title,
        style: live.done || live.failed
            ? const TextStyle(decoration: TextDecoration.lineThrough)
            : null,
      ),
      subtitle: Text(
        live.failed ? '$dueLabel · failed' : dueLabel,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: live.failed ? Theme.of(context).colorScheme.error : null,
            ),
      ),
    );
  }
}

class _TrackingCard extends StatefulWidget {
  const _TrackingCard();

  @override
  State<_TrackingCard> createState() => _TrackingCardState();
}

class _TrackingCardState extends State<_TrackingCard> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _mergePending();
  }

  Future<void> _mergePending() async {
    if (!LocationService.supported) return;
    final pending = await takePendingPoints();
    if (!mounted || pending.isEmpty) return;
    context.read<TrackingCubit>().mergePoints(pending);
  }

  Future<void> _toggle() async {
    if (_busy) return;
    final tracking = context.read<TrackingCubit>();
    final settings = context.read<SettingsCubit>();
    if (tracking.state.isRecording) {
      setState(() => _busy = true);
      try {
        LocationService.stopForegroundSampling();
        await LocationService.stopBackground();
        tracking.stopRecording();
        await _mergePending();
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    if (!settings.state.trackingEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Location tracking is off — enable it in Settings.'),
        ),
      );
      context.read<NavigationCubit>().setPage(PlannerPage.settings);
      return;
    }
    if (!LocationService.supported) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Location recording works on Android and iOS only.'),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final granted = await ensureLocationPermission();
      if (!mounted) return;
      if (!granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location permission denied')),
        );
        return;
      }
      tracking.startRecording();
      final interval = settings.state.trackingIntervalMinutes;
      LocationService.startForegroundSampling(
        intervalMinutes: interval,
        onTick: () async {
          if (!mounted) return;
          final point = await samplePosition();
          if (point != null && mounted) {
            try {
              context.read<TrackingCubit>().addPoint(point);
            } catch (_) {}
          }
        },
      );
      await LocationService.startBackground(interval);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Recording location every $interval min — see the Stats tab.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tracking = context.watch<TrackingCubit>().state;
    final settings = context.watch<SettingsCubit>().state;
    final todayCount = tracking.pointsOnDay(DateTime.now()).length;
    final recording = tracking.isRecording;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  recording ? Icons.radio_button_checked : Icons.timeline,
                  color: recording
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Day tracking',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const DayReviewScreen(),
                    ),
                  ),
                  child: const Text('Review'),
                ),
              ],
            ),
            Text(
              !settings.trackingEnabled
                  ? 'Turned off in Settings.'
                  : recording
                      ? 'Recording… $todayCount points today.'
                      : todayCount > 0
                          ? '$todayCount points recorded today.'
                          : 'Record your path to auto-report your day.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _toggle,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(recording ? Icons.stop : Icons.play_arrow),
              label: Text(recording ? 'Stop reporting' : 'Start reporting'),
              style: recording
                  ? FilledButton.styleFrom(
                      backgroundColor:
                          Theme.of(context).colorScheme.error,
                      foregroundColor:
                          Theme.of(context).colorScheme.onError,
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeTrackingCard extends StatefulWidget {
  const _TimeTrackingCard();

  @override
  State<_TimeTrackingCard> createState() => _TimeTrackingCardState();
}

class _TimeTrackingCardState extends State<_TimeTrackingCard> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      try {
        if (context.read<TaskCubit>().activeTrackingId != null) {
          setState(() {});
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final taskCubit = context.watch<TaskCubit>();
    final feedCubit = context.watch<FeedCubit>();
    final now = DateTime.now();
    final visible = feedCubit.visibleTasks(taskCubit.state);
    final selection = selectTaskTracking(visible, now);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.timer_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Time tracking',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                TextButton(
                  onPressed: () => context
                      .read<NavigationCubit>()
                      .setPage(PlannerPage.tasks),
                  child: const Text('Tasks'),
                ),
              ],
            ),
            if (selection.isEmpty)
              const _EmptyLine(
                  'No tasks to track — add one with the + button.'),
            if (selection.recording != null) ...[
              const _TimeGroupLabel('Recording now'),
              _TaskTrackLine(task: selection.recording!, highlight: true),
            ],
            if (selection.current.isNotEmpty) ...[
              const _TimeGroupLabel('Happening now'),
              for (final task in selection.current)
                _TaskTrackLine(task: task, highlight: true),
            ],
            if (selection.previous.isNotEmpty) ...[
              const _TimeGroupLabel('Just before'),
              for (final task in selection.previous)
                _TaskTrackLine(task: task),
            ],
            if (selection.next.isNotEmpty) ...[
              const _TimeGroupLabel('Up next'),
              for (final task in selection.next)
                _TaskTrackLine(task: task),
            ],
            if (selection.unscheduled.isNotEmpty) ...[
              const _TimeGroupLabel('No planned time'),
              for (final task in selection.unscheduled)
                _TaskTrackLine(task: task),
            ],
          ],
        ),
      ),
    );
  }
}

class _TimeGroupLabel extends StatelessWidget {
  final String text;

  const _TimeGroupLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(text, style: Theme.of(context).textTheme.labelMedium),
    );
  }
}

class _TaskTrackLine extends StatelessWidget {
  final Task task;
  final bool highlight;

  const _TaskTrackLine({required this.task, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final live = context.watch<TaskCubit>().byId(task.id) ?? task;
    final theme = Theme.of(context);
    final timeFormat = DateFormat('h:mm a');
    final plannedLine = live.hasPlanned &&
            live.plannedStart != null &&
            live.plannedEnd != null
        ? 'Planned ${timeFormat.format(live.plannedStart!)} – '
            '${timeFormat.format(live.plannedEnd!)}'
        : (live.due != null
            ? 'Due ${DateFormat('EEE, MMM d').format(live.due!)}'
            : 'No planned time');
    final reported = live.reportedDuration;
    final elapsed = live.timerStartedAt == null
        ? null
        : DateTime.now().difference(live.timerStartedAt!);
    final statusLine = live.failed
        ? 'Marked as failed'
        : live.isTracking && elapsed != null
            ? 'Recording ${formatStopwatch(elapsed)}'
            : reported != null &&
                    live.actualStart != null &&
                    live.actualEnd != null
                ? 'Reported ${timeFormat.format(live.actualStart!)} – '
                    '${timeFormat.format(live.actualEnd!)} (${reported.inMinutes}m)'
                : plannedLine;
    return InkWell(
      onTap: () => showTaskEditor(context, existing: live),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 4),
              child: TaskCheckbox(task: live),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    live.title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      decoration: live.failed || live.done
                          ? TextDecoration.lineThrough
                          : null,
                      color: live.failed ? theme.colorScheme.error : null,
                    ),
                  ),
                  Text(plannedLine, style: theme.textTheme.labelSmall),
                  Text(
                    statusLine,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: live.failed
                          ? theme.colorScheme.error
                          : live.isTracking
                              ? theme.colorScheme.primary
                              : null,
                      fontWeight: live.isTracking || live.failed
                          ? FontWeight.w600
                          : null,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (live.isTracking)
              FilledButton.icon(
                onPressed: () => stopTaskAndFinish(context, live.id),
                icon: const Icon(Icons.stop, size: 16),
                label: Text(
                    formatStopwatch(elapsed ?? Duration.zero)),
              )
            else
              OutlinedButton.icon(
                onPressed: live.done
                    ? null
                    : () {
                        try {
                          context
                              .read<TaskCubit>()
                              .startTracking(live.id);
                        } catch (_) {}
                      },
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('Start'),
              ),
          ],
        ),
      ),
    );
  }
}
