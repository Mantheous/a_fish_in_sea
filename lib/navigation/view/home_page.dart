import 'dart:async';

import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/navigation/view/app_drawer.dart';
import 'package:a_fish_in_sea/demo/demo_mode.dart';
import 'package:a_fish_in_sea/demo/demo_tour_card.dart';
import 'package:a_fish_in_sea/imports/view/import_inbox_card.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/nodes/service/node_tracking.dart';
import 'package:a_fish_in_sea/nodes/view/node_checkbox.dart';
import 'package:a_fish_in_sea/nodes/view/node_editor.dart';
import 'package:a_fish_in_sea/nodes/view/node_finish_sheet.dart';
import 'package:a_fish_in_sea/nodes/view/timer_edit_sheet.dart';
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

final _homeTimeFormat = DateFormat('h:mm a');
final _homeDueFormat = DateFormat('EEE, MMM d');

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
    final calendarCubit = context.watch<CalendarCubit>();
    // Memoized inside CalendarCubit by (state, day); visibleEvents is now a
    // set-based single pass with an all-enabled fast path.
    final todayEvents = feedCubit.visibleEvents(
      calendarCubit.eventsOnDay(today),
    );
    final nodeCubit = context.watch<NodeCubit>();
    final dueNodes = feedCubit.visibleNodes(
      nodeCubit.overdueAndTodayAt(today),
    );
    final weekNodes = feedCubit.visibleNodes(
      nodeCubit.dueThisWeekAt(today),
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
          if (DemoMode.isActive) const DemoTourCard(),
          const ImportInboxCard(),
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
                      for (final node in dueNodes.take(5))
                        _NodeLine(node: node, now: today),
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
                        _AssignmentLine(node: node, now: today),
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
  final DateTime now;

  const _NodeLine({required this.node, required this.now});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Parent rebuilds on NodeCubit changes; resolve without another
    // full-list watch per line.
    final live = context.read<NodeCubit>().byId(node.id) ?? node;
    final failed = live.status == NodeStatus.failed;
    final overdue = live.isOverdueAt(now);
    final status = failed
        ? 'Failed'
        : overdue
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
          color: overdue || failed
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
        event.allDay ? 'All day' : _homeTimeFormat.format(event.start),
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
  final DateTime now;

  const _AssignmentLine({required this.node, required this.now});

  @override
  Widget build(BuildContext context) {
    final feedCubit = context.read<FeedCubit>();
    final Feed? feed = node.classId == null
        ? null
        : feedCubit.byId(node.classId!);
    final label = node.classLabel ?? feed?.name ?? 'Node';
    final live = context.read<NodeCubit>().byId(node.id) ?? node;
    final failed = live.status == NodeStatus.failed;
    final due = live.schedule?.due;
    final dueLabel = due == null
        ? label
        : '$label · due ${_homeDueFormat.format(due)}';
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
    final trackingCubit = context.watch<TrackingCubit>();
    final tracking = trackingCubit.state;
    final settings = context.watch<SettingsCubit>().state;
    // Indexed bucket (one O(p) pass per state change, O(1) here).
    final todayCount = trackingCubit.pointsOnDay(DateTime.now()).length;
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
  StreamSubscription? _nodeSub;
  List<Node>? _lastNodes;
  NodeTrackingSelection? _cachedSelection;
  DateTime? _cachedDayMinute;

  @override
  void initState() {
    super.initState();
    // Start the 1s ticker only while a timer is actually recording. The old
    // code woke the isolate every second for Home's whole lifetime even
    // with zero tracking nodes.
    try {
      final cubit = context.read<NodeCubit>();
      _syncTicker(cubit.state);
      _nodeSub = cubit.stream.listen(_syncTicker);
    } catch (_) {}
  }

  void _syncTicker(List<Node> nodes) {
    final hasActive = nodes.any((n) => n.isTracking);
    if (hasActive && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
      });
    } else if (!hasActive && _ticker != null) {
      _ticker?.cancel();
      _ticker = null;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _nodeSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nodeCubit = context.watch<NodeCubit>();
    final feedCubit = context.watch<FeedCubit>();
    final now = DateTime.now();
    // Re-run selection only when inputs change or the minute rolls over;
    // the 1s ticker only needs to advance elapsed labels, not re-sort.
    final nodes = nodeCubit.state;
    final minute = DateTime(now.year, now.month, now.day, now.hour, now.minute);
    NodeTrackingSelection selection;
    if (identical(nodes, _lastNodes) &&
        _cachedSelection != null &&
        minute == _cachedDayMinute) {
      selection = _cachedSelection!;
    } else {
      final visible = feedCubit.visibleNodes(nodes);
      selection = selectNodeTracking(visible, now);
      _lastNodes = nodes;
      _cachedSelection = selection;
      _cachedDayMinute = minute;
    }
    // Resolve liveness once for the handful of displayed lines.
    final liveById = {for (final n in nodes) n.id: n};
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
              _NodeTrackLine(
                node: liveById[selection.recording!.id] ?? selection.recording!,
                highlight: true,
                now: now,
              ),
            ],
            if (selection.current.isNotEmpty) ...[
              const _TimeGroupLabel('Happening now'),
              for (final node in selection.current)
                _NodeTrackLine(
                  node: liveById[node.id] ?? node,
                  highlight: true,
                  now: now,
                ),
            ],
            if (selection.previous.isNotEmpty) ...[
              const _TimeGroupLabel('Just before'),
              for (final node in selection.previous)
                _NodeTrackLine(
                  node: liveById[node.id] ?? node,
                  now: now,
                ),
            ],
            if (selection.next.isNotEmpty) ...[
              const _TimeGroupLabel('Up next'),
              for (final node in selection.next)
                _NodeTrackLine(
                  node: liveById[node.id] ?? node,
                  now: now,
                ),
            ],
            if (selection.unscheduled.isNotEmpty) ...[
              const _TimeGroupLabel('No planned time'),
              for (final node in selection.unscheduled)
                _NodeTrackLine(
                  node: liveById[node.id] ?? node,
                  now: now,
                ),
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
  final DateTime now;

  const _NodeTrackLine({
    required this.node,
    this.highlight = false,
    required this.now,
  });

  @override
  Widget build(BuildContext context) {
    // `node` is already the live instance from the parent's hoisted map —
    // no per-line watch (which subscribed every line to the full list).
    final live = node;
    final failed = live.status == NodeStatus.failed;
    final theme = Theme.of(context);
    final plannedStart = live.schedule?.start;
    final plannedEnd = live.schedule?.end;
    final plannedLine = plannedStart != null && plannedEnd != null
        ? 'Planned ${_homeTimeFormat.format(plannedStart)} – '
            '${_homeTimeFormat.format(plannedEnd)}'
        : (live.schedule?.due != null
            ? 'Due ${_homeDueFormat.format(live.schedule!.due!)}'
            : 'No planned time');
    final reported = live.reportedDuration;
    final elapsed = live.timerStartedAt == null
        ? null
        : now.difference(live.timerStartedAt!);
    final isReportedShown = reported != null &&
        live.actualStart != null &&
        live.actualEnd != null;
    final statusLine = failed
        ? 'Marked as failed'
        : live.isTracking && elapsed != null
            ? 'Recording ${formatStopwatch(elapsed)}'
            : isReportedShown
                ? 'Reported ${_homeTimeFormat.format(live.actualStart!)} – '
                    '${_homeTimeFormat.format(live.actualEnd!)} (${reported.inMinutes}m)'
                : plannedLine;
    // Toggl-style: the status line opens the correction sheet — a late
    // press is fixed by moving the start, a finished session by editing
    // the interval. Only when there is something to correct.
    final canEditTimer = live.isTracking || isReportedShown;
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
                  if (canEditTimer)
                    InkWell(
                      onTap: () => showEditNodeTimerSheet(
                        context,
                        nodeId: live.id,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
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
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.edit,
                            size: 12,
                            color: theme.colorScheme.outline,
                          ),
                        ],
                      ),
                    )
                  else
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
                          NodeEventLink.startNodeTracking(
                            context.read<NodeCubit>(),
                            context.read<CalendarCubit>(),
                            live.id,
                          );
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
