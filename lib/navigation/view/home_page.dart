import 'dart:async';

import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/navigation/view/app_drawer.dart';
import 'package:a_fish_in_sea/demo/demo_mode.dart';
import 'package:a_fish_in_sea/demo/demo_tour_card.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/imports/view/import_inbox_card.dart';
import 'package:a_fish_in_sea/navigation/view/favorite_goal_line.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/goal_progress_snapshot.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/nodes/service/node_tracking.dart';
import 'package:a_fish_in_sea/nodes/view/node_checkbox.dart';
import 'package:a_fish_in_sea/nodes/view/node_editor.dart';
import 'package:a_fish_in_sea/nodes/view/node_finish_sheet.dart';
import 'package:a_fish_in_sea/nodes/view/quick_record_sheet.dart';
import 'package:a_fish_in_sea/nodes/view/timer_edit_sheet.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/event_tracking.dart';
import 'home_tracking_card.dart';
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
    final dueNodes = feedCubit.visibleNodes(nodeCubit.overdueAndTodayAt(today));
    final weekNodes = feedCubit.visibleNodes(nodeCubit.dueThisWeekAt(today));
    final favoriteNodes = feedCubit.visibleNodes(nodeCubit.favorites);
    // One aggregation pass per build for all favorite rows; null when the
    // section is empty so an empty Home never walks the store.
    final favoriteProgress = favoriteNodes.isEmpty
        ? null
        : buildGoalProgressSnapshot(
            nodes: nodeCubit.state,
            transactions: context.watch<TransactionsCubit>().state,
            now: today,
          );
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      drawer: const AppDrawer(),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'home-add',
            tooltip: 'Add goal or task',
            onPressed: () => showNodeEditor(context),
            child: const Icon(Icons.add),
          ),
          const SizedBox(height: 8),
          // Recording a new ad-hoc task is the common quick capture on
          // this page, so it gets the labelled FAB; full editing stays on
          // the small + above it.
          FloatingActionButton.extended(
            heroTag: 'home-record',
            onPressed: () => showQuickRecordSheet(context),
            icon: const Icon(Icons.fiber_manual_record),
            label: const Text('Record'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (DemoMode.isActive) const DemoTourCard(),
          const ImportInboxCard(),
          const _TimeTrackingCard(),
          const HomeTrackingCard(),
          _SectionCard(
            title: 'Favorite goals',
            onMore: () =>
                context.read<NavigationCubit>().setPage(PlannerPage.nodes),
            child: favoriteProgress == null
                ? const _EmptyLine(
                    'No favorite goals — star a goal to pin it here',
                  )
                : Column(
                    children: [
                      for (final node in favoriteNodes.take(5))
                        FavoriteGoalLine(
                          node: node,
                          now: today,
                          snapshot: favoriteProgress,
                        ),
                    ],
                  ),
          ),
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
                      for (final event in todayEvents) _EventLine(event: event),
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
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(onPressed: onMore, child: const Text('See all')),
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
          color: overdue || failed ? theme.colorScheme.error : null,
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
                  child: Text(
                    'Time tracking',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: () => context.read<NavigationCubit>().setPage(
                    PlannerPage.tasks,
                  ),
                  child: const Text('Tasks'),
                ),
              ],
            ),
            if (selection.recording == null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: OutlinedButton.icon(
                  onPressed: () => showQuickRecordSheet(context),
                  icon: const Icon(
                    Icons.fiber_manual_record,
                    size: 16,
                    color: Color(0xFFFF5252),
                  ),
                  label: const Text('Record something new'),
                ),
              ),
            if (selection.isEmpty)
              const _EmptyLine(
                'No nodes to track — record something new or add one with '
                'the + button.',
              ),
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
                _NodeTrackLine(node: liveById[node.id] ?? node, now: now),
            ],
            if (selection.next.isNotEmpty) ...[
              const _TimeGroupLabel('Up next'),
              for (final node in selection.next)
                _NodeTrackLine(node: liveById[node.id] ?? node, now: now),
            ],
            if (selection.unscheduled.isNotEmpty) ...[
              const _TimeGroupLabel('No planned time'),
              for (final node in selection.unscheduled)
                _NodeTrackLine(node: liveById[node.id] ?? node, now: now),
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
    final sessions = live.recordedSessions;
    final isReportedShown = reported != null && sessions.isNotEmpty;
    final reportLabel = reported == null
        ? null
        : reported.inMinutes == 0
        ? '${reported.inSeconds}s'
        : '${reported.inMinutes}m';
    final statusLine = failed
        ? 'Marked as failed'
        : live.isTracking
        ? 'Recording ${formatStopwatch(elapsed ?? Duration.zero)}'
        : isReportedShown
        ? sessions.length > 1
              ? 'Reported ${sessions.length} sessions · $reportLabel'
              : 'Reported ${_homeTimeFormat.format(sessions.single.start)} – '
                    '${_homeTimeFormat.format(sessions.single.end)} '
                    '($reportLabel)'
        : null;
    // Only a running timer is corrected here (move its start). Finished
    // recordings are edited as chips in Calendar → Plan + Report.
    final canEditTimer = live.isTracking;
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
                      onTap: () =>
                          showEditNodeTimerSheet(context, nodeId: live.id),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              statusLine!,
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
                  else if (statusLine != null)
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
                label: Text(formatStopwatch(elapsed ?? Duration.zero)),
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
