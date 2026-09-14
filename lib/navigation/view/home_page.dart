import 'dart:async';

import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/navigation/view/app_drawer.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_tracking.dart';
import 'package:a_fish_in_sea/nodes/view/node_checkbox.dart';
import 'package:a_fish_in_sea/nodes/view/node_editor.dart';
import 'package:a_fish_in_sea/nodes/view/node_finish_sheet.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/event_tracking.dart';
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
    final nodeCubit = context.watch<NodeCubit>();
    final dueNodes = feedCubit.visibleNodes(
      nodeCubit.overdueAndToday,
    );
    final weekNodes = feedCubit.visibleNodes(
      nodeCubit.dueThisWeek,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      drawer: const AppDrawer(),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showNodeEditor(context),
        child: const Icon(Icons.add),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const _TimeTrackingCard(),
          const _TrackingCard(),
          _SectionCard(
            title: 'Due today',
            onMore: () =>
                context.read<NavigationCubit>().setPage(PlannerPage.tasks),
            child: dueNodes.isEmpty
                ? const _EmptyLine('Nothing due today')
                : Column(
                    children: [
                      for (final node in dueNodes.take(5)) _NodeLine(node: node),
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
            title: 'Due this week',
            onMore: () =>
                context.read<NavigationCubit>().setPage(PlannerPage.tasks),
            child: weekNodes.isEmpty
                ? const _EmptyLine('No nodes due this week')
                : Column(
                    children: [
                      for (final node in weekNodes)
                        _AssignmentLine(node: node),
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

class _NodeLine extends StatelessWidget {
  final Node node;

  const _NodeLine({required this.node});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final live = context.watch<NodeCubit>().byId(node.id) ?? node;
    final failed = live.status == NodeStatus.failed;
    final status = failed
        ? 'Failed'
        : live.isOverdueAt(DateTime.now())
            ? 'Overdue'
            : 'Due today';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: NodeCheckbox(node: live),
      title: Text(
        live.title,
        style: live.isDone || failed
            ? TextStyle(
                decoration: TextDecoration.lineThrough,
                color: failed ? theme.colorScheme.error : null,
              )
            : null,
      ),
      subtitle: Text(
        status,
        style: theme.textTheme.labelSmall?.copyWith(
          color: live.isOverdueAt(DateTime.now()) || failed
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
  final Node node;

  const _AssignmentLine({required this.node});

  @override
  Widget build(BuildContext context) {
    final feedCubit = context.read<FeedCubit>();
    final Feed? feed = node.classId == null
        ? null
        : feedCubit.byId(node.classId!);
    final formatter = DateFormat('EEE, MMM d');
    final label = node.classLabel ?? feed?.name ?? 'Node';
    final live = context.watch<NodeCubit>().byId(node.id) ?? node;
    final failed = live.status == NodeStatus.failed;
    final due = live.schedule?.due;
    final dueLabel = due == null
        ? label
        : '$label · due ${formatter.format(due)}';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: NodeCheckbox(node: live),
      title: Text(
        live.title,
        style: live.isDone || failed
            ? const TextStyle(decoration: TextDecoration.lineThrough)
            : null,
      ),
      subtitle: Text(
        failed ? '$dueLabel · failed' : dueLabel,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: failed ? Theme.of(context).colorScheme.error : null,
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
    final pending = await takePendingPoints();
    if (!mounted || pending.isEmpty) return;
    try {
      context.read<TrackingCubit>().mergePoints(pending);
    } catch (_) {}
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
    final gpsAvailable = LocationService.supported;
    setState(() => _busy = true);
    try {
      if (gpsAvailable) {
        final granted = await ensureLocationPermission();
        if (!mounted) return;
        if (!granted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permission denied')),
          );
          return;
        }
      }
      tracking.startRecording();
      final interval = settings.state.trackingIntervalMinutes;
      // Capture the cubit up front: the old onTick closed over `mounted` /
      // `context`, so leaving Home disposed the card and silently stopped
      // all foreground sampling while `isRecording` stayed true.
      final trackingCubit = context.read<TrackingCubit>();
      var background = false;
      if (gpsAvailable) {
        LocationService.startForegroundSampling(
          intervalMinutes: interval,
          onTick: () async {
            final point = await samplePosition();
            if (point == null || trackingCubit.isClosed) return;
            try {
              trackingCubit.addPoint(point);
            } catch (_) {}
          },
        );
        background = await LocationService.startBackground(interval);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              !gpsAvailable
                  ? 'Recording started (no GPS on this device) — add test points from Day review.'
                  : background
                      ? 'Recording location every $interval min — see the Stats tab.'
                      : 'Recording while the app is open. Allow notifications to keep recording in the background.',
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
              label: Text(recording ? 'Stop recording' : 'Start recording'),
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
        if (context.read<NodeCubit>().activeTrackingId != null) {
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
    final nodeCubit = context.watch<NodeCubit>();
    final feedCubit = context.watch<FeedCubit>();
    final now = DateTime.now();
    final visible = feedCubit.visibleNodes(nodeCubit.state);
    final selection = selectNodeTracking(visible, now);
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
                  'No nodes to track — add one with the + button.'),
            if (selection.recording != null) ...[
              const _TimeGroupLabel('Recording now'),
              _NodeTrackLine(node: selection.recording!, highlight: true),
            ],
            if (selection.current.isNotEmpty) ...[
              const _TimeGroupLabel('Happening now'),
              for (final node in selection.current)
                _NodeTrackLine(node: node, highlight: true),
            ],
            if (selection.previous.isNotEmpty) ...[
              const _TimeGroupLabel('Just before'),
              for (final node in selection.previous)
                _NodeTrackLine(node: node),
            ],
            if (selection.next.isNotEmpty) ...[
              const _TimeGroupLabel('Up next'),
              for (final node in selection.next)
                _NodeTrackLine(node: node),
            ],
            if (selection.unscheduled.isNotEmpty) ...[
              const _TimeGroupLabel('No planned time'),
              for (final node in selection.unscheduled)
                _NodeTrackLine(node: node),
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

class _NodeTrackLine extends StatelessWidget {
  final Node node;
  final bool highlight;

  const _NodeTrackLine({required this.node, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final live = context.watch<NodeCubit>().byId(node.id) ?? node;
    final failed = live.status == NodeStatus.failed;
    final theme = Theme.of(context);
    final timeFormat = DateFormat('h:mm a');
    final plannedStart = live.schedule?.start;
    final plannedEnd = live.schedule?.end;
    final plannedLine = plannedStart != null && plannedEnd != null
        ? 'Planned ${timeFormat.format(plannedStart)} – '
            '${timeFormat.format(plannedEnd)}'
        : (live.schedule?.due != null
            ? 'Due ${DateFormat('EEE, MMM d').format(live.schedule!.due!)}'
            : 'No planned time');
    final reported = live.reportedDuration;
    final elapsed = live.timerStartedAt == null
        ? null
        : DateTime.now().difference(live.timerStartedAt!);
    final statusLine = failed
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
      onTap: () => showNodeEditor(context, existing: live),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 4),
              child: NodeCheckbox(node: live),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    live.title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      decoration: failed || live.isDone
                          ? TextDecoration.lineThrough
                          : null,
                      color: failed ? theme.colorScheme.error : null,
                    ),
                  ),
                  Text(plannedLine, style: theme.textTheme.labelSmall),
                  Text(
                    statusLine,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: failed
                          ? theme.colorScheme.error
                          : live.isTracking
                              ? theme.colorScheme.primary
                              : null,
                      fontWeight: live.isTracking || failed
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
                onPressed: () => stopNodeAndFinish(context, live.id),
                icon: const Icon(Icons.stop, size: 16),
                label: Text(
                    formatStopwatch(elapsed ?? Duration.zero)),
              )
            else
              OutlinedButton.icon(
                onPressed: live.isDone
                    ? null
                    : () {
                        try {
                          context
                              .read<NodeCubit>()
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
