import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../common/undo/undo_bar.dart';
import '../../common/undo/undo_cubit.dart';
import '../../navigation/bloc/navigation_cubit.dart';
import '../../navigation/view/app_drawer.dart';
import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/model/node.dart';
import '../../nodes/service/node_progress.dart';
import '../../nodes/view/node_checkbox.dart';
import '../../nodes/view/node_editor.dart';
import '../../nodes/view/node_finish_sheet.dart';
import '../bloc/calendar_cubit.dart';
import '../bloc/calendar_draft_cubit.dart';
import '../bloc/feed_cubit.dart';
import '../bloc/tasks_tab_cubit.dart';
import '../model/feed.dart';
import '../model/planner_event.dart';
import '../model/task_assignee.dart';
import 'feed_manager.dart';
import 'syllabus_import_sheet.dart';

class TasksPage extends StatelessWidget {
  const TasksPage({super.key});

  /// Tab the user was last on (0 = To-Do, 1 = Homework). Falls back to 0
  /// when the cubit isn't provided (widget tests pump TasksPage standalone).
  static int _initialTab(BuildContext context) {
    try {
      final i = context.read<TasksTabCubit>().state;
      if (i < 0 || i > 1) return 0;
      return i;
    } catch (_) {
      return 0;
    }
  }

  static void _saveTab(BuildContext context, int index) {
    try {
      context.read<TasksTabCubit>().setTab(index);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: _initialTab(context),
      child: Builder(
        builder: (context) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('Tasks'),
              actions: [
                IconButton(
                  tooltip: 'Import from syllabus',
                  icon: const Icon(Icons.auto_awesome),
                  onPressed: () => showSyllabusImport(context),
                ),
                IconButton(
                  tooltip: 'Manage classes',
                  icon: const Icon(Icons.sync),
                  onPressed: () => showFeedManager(context),
                ),
                const UndoRedoActions(),
              ],
              bottom: TabBar(
                onTap: (i) => _saveTab(context, i),
                tabs: const [
                  Tab(text: 'To-Do'),
                  Tab(text: 'Homework'),
                ],
              ),
            ),
            drawer: const AppDrawer(),
            floatingActionButton: FloatingActionButton(
              onPressed: () => showNodeEditor(context),
              child: const Icon(Icons.add),
            ),
            body: _TabSaver(
              child: TabBarView(
                children: const [
                  _TodoTab(),
                  _HomeworkTab(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Persists swipe-driven tab changes (TabBar.onTap only fires on taps, not
/// on TabBarView swipes). Listens to the DefaultTabController and records
/// the settled index in [TasksTabCubit]; tolerates a missing cubit so
/// standalone widget tests keep working.
class _TabSaver extends StatefulWidget {
  final Widget child;

  const _TabSaver({required this.child});

  @override
  State<_TabSaver> createState() => _TabSaverState();
}

class _TabSaverState extends State<_TabSaver> {
  TabController? _controller;

  void _onTabChanged() {
    final controller = _controller;
    if (controller == null || controller.indexIsChanging) return;
    try {
      context.read<TasksTabCubit>().setTab(controller.index);
    } catch (_) {}
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = DefaultTabController.of(context);
    if (_controller != next) {
      _controller?.removeListener(_onTabChanged);
      _controller = next;
      _controller?.addListener(_onTabChanged);
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTabChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

final _timeFormat = DateFormat('h:mm a');
final _dueFormat = DateFormat('EEE, MMM d');

class _TodoTab extends StatelessWidget {
  const _TodoTab();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NodeCubit, List<Node>>(
      builder: (context, nodes) {
        final feedCubit = context.watch<FeedCubit>();
        final open = feedCubit.visibleNodes(
          context.read<NodeCubit>().openNodes,
        );
        if (open.isEmpty) return const _EmptyTodo();
        // Precompute once per list build (not per tile): calendar link set,
        // feed map, node indexes, and a single `now`. Tiles receive plain
        // data and use `read` — no per-tile full-state watches.
        final calendarState = context.watch<CalendarCubit>().state;
        final now = DateTime.now();
        final linkedEventIds = <String>{};
        final linkedTaskIds = <String>{};
        for (final e in calendarState) {
          linkedEventIds.add(e.id);
          final t = e.taskId;
          if (t != null) linkedTaskIds.add(t);
        }
        final feedById = {for (final f in feedCubit.state) f.id: f};
        final nodeById = {for (final n in nodes) n.id: n};
        final indexes = buildNodeIndexes(nodes);
        return ListView.builder(
          itemCount: open.length,
          itemBuilder: (context, index) {
            final node = open[index];
            return _NodeTile(
              node: node,
              showClass: true,
              now: now,
              feedById: feedById,
              nodeById: nodeById,
              indexById: indexes.byId,
              indexByParent: indexes.byParent,
              linkedEventIds: linkedEventIds,
              linkedTaskIds: linkedTaskIds,
            );
          },
        );
      },
    );
  }
}

class _EmptyTodo extends StatelessWidget {
  const _EmptyTodo();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline, size: 48),
          const SizedBox(height: 8),
          Text('Nothing to do!',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Add a node with the + button'),
          const SizedBox(height: 12),
          Builder(
            builder: (context) => OutlinedButton.icon(
              onPressed: () => showSyllabusImport(context),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Import from syllabus'),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeworkTab extends StatefulWidget {
  const _HomeworkTab();

  @override
  State<_HomeworkTab> createState() => _HomeworkTabState();
}

class _HomeworkTabState extends State<_HomeworkTab>
    with AutomaticKeepAliveClientMixin {
  /// Class groups the user collapsed. New groups default to expanded.
  final Set<String> _collapsed = {};

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final nodeCubit = context.watch<NodeCubit>();
    final feedCubit = context.watch<FeedCubit>();
    final imported = feedCubit.visibleNodes(
        nodeCubit.state.where((n) => n.isHomework).toList());
    if (imported.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.school_outlined, size: 48),
              const SizedBox(height: 8),
              Text(
                'No homework yet',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              const Text(
                'Add a class with its iCal link and assignments '
                'will show up here automatically.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => showFeedManager(context),
                icon: const Icon(Icons.add),
                label: const Text('Add a class'),
              ),
            ],
          ),
        ),
      );
    }
    final byClass = <String, List<Node>>{};
    for (final node in imported) {
      final key = node.classLabel ?? node.classId ?? '';
      byClass.putIfAbsent(key, () => []).add(node);
    }
    // Sorted keys keep tile order stable across rebuilds so expansion
    // state never jumps to the wrong class.
    final groupKeys = byClass.keys.toList()..sort();
    // Hoisted per-build (not per-tile/per-group): feed map, node liveness
    // map, shared money indexes, calendar link sets, one `now`. Sort each
    // group once up front instead of inside the itemBuilder on every
    // rebuild (the old `..sort` mutated the list during build).
    final now = DateTime.now();
    final feedById = {for (final f in feedCubit.state) f.id: f};
    final allNodes = nodeCubit.state;
    final nodeById = {for (final n in allNodes) n.id: n};
    final indexes = buildNodeIndexes(allNodes);
    final calendarState = context.watch<CalendarCubit>().state;
    final linkedEventIds = <String>{};
    final linkedTaskIds = <String>{};
    for (final e in calendarState) {
      linkedEventIds.add(e.id);
      final t = e.taskId;
      if (t != null) linkedTaskIds.add(t);
    }
    final groupNodes = <String, List<Node>>{};
    final groupOpenCount = <String, int>{};
    final groupMeta = <String, ({Color color, String name})>{};
    for (final key in groupKeys) {
      final list = byClass[key]!..sort(_compare);
      groupNodes[key] = list;
      var openCount = 0;
      for (final n in list) {
        if (n.isOpen) openCount++;
      }
      groupOpenCount[key] = openCount;
      final labeled = !list.every((node) => node.classLabel == null);
      if (labeled) {
        groupMeta[key] = (color: courseColor(key), name: key);
      } else {
        final feed = feedById[key];
        groupMeta[key] = (
          color: feed == null
              ? Theme.of(context).colorScheme.primary
              : mutedCalendarColor(feed.color),
          name: feed?.name ?? 'Unknown class',
        );
      }
    }
    return Column(
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: feedCubit.isSyncing,
          builder: (context, syncing, _) => ListTile(
            dense: true,
            title: Text(
              syncing ? 'Syncing…' : 'Assignments by class',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            trailing: IconButton(
              icon: syncing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              onPressed:
                  syncing ? null : () => feedCubit.syncAll(force: true),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: groupKeys.length,
            itemBuilder: (context, index) {
              final groupKey = groupKeys[index];
              final meta = groupMeta[groupKey]!;
              final classNodes = groupNodes[groupKey]!;
              return Card(
                margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                child: ExpansionTile(
                  key: PageStorageKey<String>('homework-$groupKey'),
                  initiallyExpanded: !_collapsed.contains(groupKey),
                  onExpansionChanged: (expanded) {
                    setState(() {
                      if (expanded) {
                        _collapsed.remove(groupKey);
                      } else {
                        _collapsed.add(groupKey);
                      }
                    });
                  },
                  leading: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: meta.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  title:
                      Text(meta.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${groupOpenCount[groupKey]} to do',
                  ),
                  children: [
                    for (final node in classNodes)
                      _NodeTile(
                        node: node,
                        showClass: false,
                        now: now,
                        feedById: feedById,
                        nodeById: nodeById,
                        indexById: indexes.byId,
                        indexByParent: indexes.byParent,
                        linkedEventIds: linkedEventIds,
                        linkedTaskIds: linkedTaskIds,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  static int _compare(Node a, Node b) {
    final aDue = a.schedule?.due;
    final bDue = b.schedule?.due;
    if (aDue == null && bDue == null) return 0;
    if (aDue == null) return 1;
    if (bDue == null) return -1;
    return aDue.compareTo(bDue);
  }
}

bool _isDueToday(DateTime due, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(due.year, due.month, due.day);
  return day == today;
}

class _NodeTile extends StatelessWidget {
  final Node node;
  final bool showClass;
  // Hoisted per-list data (all optional for backwards compat): when
  // supplied the tile avoids per-tile `watch` subscriptions and O(n) scans.
  final DateTime? now;
  final Map<String, Feed>? feedById;
  final Map<String, Node>? nodeById;
  final Map<String, Node>? indexById;
  final Map<String, List<Node>>? indexByParent;
  final Set<String>? linkedEventIds;
  final Set<String>? linkedTaskIds;

  const _NodeTile({
    required this.node,
    required this.showClass,
    this.now,
    this.feedById,
    this.nodeById,
    this.indexById,
    this.indexByParent,
    this.linkedEventIds,
    this.linkedTaskIds,
  });
  @override
  Widget build(BuildContext context) {
    final nodeCubit = context.read<NodeCubit>();
    // Fast path: parent already rebuilt on NodeCubit changes, so resolve
    // liveness from the hoisted map instead of subscribing every tile to
    // the full node list (N tiles × full-state subscription + O(n) byId
    // each = O(n²) per edit).
    final live = nodeById?[node.id] ??
        context.read<NodeCubit>().byId(node.id) ??
        node;
    final failed = live.status == NodeStatus.failed;
    final effectiveNow = now ?? DateTime.now();
    final Color chipColor;
    final String chipLabel;
    if (showClass && live.classLabel != null) {
      chipColor = courseColor(live.classLabel!);
      chipLabel = live.classLabel!;
    } else {
      Feed? feed;
      if (showClass && live.classId != null) {
        final map = feedById;
        feed = map != null
            ? map[live.classId]
            : context.read<FeedCubit>().byId(live.classId!);
      }
      chipColor = feed == null
          ? Theme.of(context).colorScheme.primary
          : mutedCalendarColor(feed.color);
      chipLabel = feed?.name ?? '';
    }
    final hasChip = chipLabel.isNotEmpty;
    final theme = Theme.of(context);
    final hasEvent = _hasCalendarEventFast(
      live,
      linkedEventIds: linkedEventIds,
      linkedTaskIds: linkedTaskIds,
    ) ??
        _hasCalendarEvent(
            live, context.read<CalendarCubit>().state);
    String? workLine;
    final plannedStart = live.schedule?.start;
    final plannedEnd = live.schedule?.end;
    if (failed) {
      workLine = 'Failed';
    } else if (live.isTracking) {
      workLine = 'Recording…';
    } else if (live.hasReported && live.reportedDuration != null) {
      final planned = live.schedule?.plannedDuration;
      workLine = planned == null
          ? 'Reported ${live.reportedDuration!.inMinutes}m'
          : 'Reported ${live.reportedDuration!.inMinutes}m '
              '(planned ${planned.inMinutes}m)';
    } else if (plannedStart != null && plannedEnd != null) {
      workLine = 'Planned ${_timeFormat.format(plannedStart)} – '
          '${_timeFormat.format(plannedEnd)}';
    } else if (live.money != null) {
      final actual = (indexById != null && indexByParent != null)
          ? moneyActualForNodeIndexed(
              live,
              byId: indexById!,
              byParent: indexByParent!,
            )
          : moneyActualForNode(
              live, context.read<NodeCubit>().state);
      workLine =
          '\$${actual.toStringAsFixed(2)} / \$${live.money!.effectiveTarget.toStringAsFixed(2)}';
    }
    final due = live.schedule?.due;
    return ListTile(
      leading: NodeCheckbox(node: live),
      title: Text(
        live.title,
        style: TextStyle(
          decoration:
              live.isDone || failed ? TextDecoration.lineThrough : null,
          color: failed
              ? theme.colorScheme.error
              : live.isDone
                  ? theme.colorScheme.outline
                  : null,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (hasChip)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: chipColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    Flexible(
                      child: Text(
                        chipLabel,
                        style: theme.textTheme.labelSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              if (due != null)
                Text(
                  'Due ${_dueFormat.format(due)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: live.isOverdueAt(effectiveNow)
                        ? theme.colorScheme.error
                        : null,
                    fontWeight: _isDueToday(due, effectiveNow)
                        ? FontWeight.bold
                        : null,
                  ),
                ),
            ],
          ),
          if (workLine != null)
            Text(
              workLine,
              style: theme.textTheme.labelSmall?.copyWith(
                color: failed
                    ? theme.colorScheme.error
                    : live.isTracking
                        ? theme.colorScheme.primary
                        : null,
                fontWeight: failed || live.isTracking
                    ? FontWeight.w600
                    : null,
              ),
            ),
          if (live.assignees.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: _AssigneeLine(assignees: live.assignees),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          IconButton(
            tooltip: live.isTracking ? 'Stop recording' : 'Start recording',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(),
            icon: Icon(
              live.isTracking ? Icons.stop : Icons.play_arrow,
              color: live.isTracking ? theme.colorScheme.primary : null,
            ),
            onPressed: live.isDone
                ? null
                : () {
                    if (live.isTracking) {
                      stopNodeAndFinish(context, live.id);
                    } else {
                      try {
                        nodeCubit.startTracking(live.id);
                      } catch (_) {}
                    }
                  },
          ),
          IconButton(
            tooltip: hasEvent
                ? 'Event added — tap to add another'
                : 'Add to calendar',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(),
            icon: Icon(
              Icons.event_available,
              color: hasEvent ? theme.colorScheme.primary : null,
            ),
            onPressed: () => _addToCalendar(context, live),
          ),
          PopupMenuButton<String>(
            padding: EdgeInsets.zero,
            onSelected: (value) {
              if (value == 'edit') {
                showNodeEditor(context, existing: live);
              }
              if (value == 'delete') _delete(context, live);
              if (value == 'calendar') _addToCalendar(context, live);
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(
                value: 'calendar',
                child: Text('Add to calendar'),
              ),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
      onTap: () => showNodeEditor(context, existing: live),
    );
  }

  /// O(1) link check against hoisted sets. Returns null when the sets
  /// weren't supplied so callers fall back to the O(n) scan.
  static bool? _hasCalendarEventFast(
    Node node, {
    Set<String>? linkedEventIds,
    Set<String>? linkedTaskIds,
  }) {
    if (linkedEventIds == null || linkedTaskIds == null) return null;
    final linkedId = node.calendarEventId;
    if (linkedId != null && linkedEventIds.contains(linkedId)) return true;
    return linkedTaskIds.contains(node.id);
  }

  static bool _hasCalendarEvent(
      Node node, List<PlannerEvent> calendarEvents) {
    final linkedId = node.calendarEventId;
    if (linkedId != null) {
      for (final event in calendarEvents) {
        if (event.id == linkedId) return true;
      }
    }
    for (final event in calendarEvents) {
      if (event.taskId != null && event.taskId == node.id) return true;
    }
    return false;
  }

  void _addToCalendar(BuildContext context, Node node) {
    context.read<CalendarDraftCubit>().requestDraft(
          draftSeedFromNode(node),
        );
    context.read<NavigationCubit>().setPage(PlannerPage.calendar);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Pick a time on the calendar — nothing is saved until you press Add.',
        ),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _delete(BuildContext context, Node node) {
    final eventId = node.calendarEventId ?? node.sourceEventId;
    context.read<NodeCubit>().deleteNode(node.id);
    if (eventId != null) {
      try {
        context.read<CalendarCubit>().clearTaskLink(eventId);
      } catch (_) {}
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Node deleted'),
          duration: const Duration(seconds: 4),
          // Action snackbars persist forever by default; this one must go.
          persist: false,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => context.read<UndoCubit>().undo(),
          ),
        ),
      );
  }
}

class _AssigneeLine extends StatelessWidget {
  final List<TaskAssignee> assignees;

  const _AssigneeLine({required this.assignees});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = assignees.take(3).toList();
    final extra = assignees.length - shown.length;
    final names = shown.map((a) => a.displayName).join(', ');
    return Row(
      children: [
        SizedBox(
          width: shown.length * 18.0 + 4,
          height: 20,
          child: Stack(
            children: [
              for (var i = 0; i < shown.length; i++)
                Positioned(
                  left: i * 18.0,
                  child: CircleAvatar(
                    radius: 10,
                    child: Text(
                      shown[i].displayName.isEmpty
                          ? '?'
                          : shown[i].displayName[0].toUpperCase(),
                      style: const TextStyle(fontSize: 10),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            extra > 0 ? '$names +$extra' : names,
            style: theme.textTheme.labelSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
