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
import '../model/feed.dart';
import '../model/planner_event.dart';
import '../model/task_assignee.dart';
import 'feed_manager.dart';
import 'syllabus_import_sheet.dart';

class TasksPage extends StatelessWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
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
          bottom: const TabBar(
            tabs: [
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
        body: TabBarView(
          children: [
            const _TodoTab(),
            const _HomeworkTab(),
          ],
        ),
      ),
    );
  }
}

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
        return ListView(
          children: [
            if (open.isEmpty)
              const _EmptyTodo()
            else
              for (final node in open)
                _NodeTile(node: node, showClass: true),
          ],
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
              final labeled = !byClass[groupKey]!.every(
                (node) => node.classLabel == null,
              );
              final Color groupColor;
              final String groupName;
              if (labeled) {
                groupColor = courseColor(groupKey);
                groupName = groupKey;
              } else {
                final feed = feedCubit.byId(groupKey);
                groupColor = feed == null
                    ? Theme.of(context).colorScheme.primary
                    : mutedCalendarColor(feed.color);
                groupName = feed?.name ?? 'Unknown class';
              }
              final classNodes = byClass[groupKey]!..sort(_compare);
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
                      color: groupColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  title:
                      Text(groupName, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${classNodes.where((n) => n.isOpen).length} to do',
                  ),
                  children: [
                    for (final node in classNodes)
                      _NodeTile(node: node, showClass: false),
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

  const _NodeTile({required this.node, required this.showClass});
  @override
  Widget build(BuildContext context) {
    final nodeCubit = context.read<NodeCubit>();
    final feedCubit = context.watch<FeedCubit>();
    final allNodes = context.watch<NodeCubit>().state;
    final calendarEvents = context.watch<CalendarCubit>().state;
    final live = context.watch<NodeCubit>().byId(node.id) ?? node;
    final failed = live.status == NodeStatus.failed;
    final now = DateTime.now();
    final Color chipColor;
    final String chipLabel;
    if (showClass && live.classLabel != null) {
      chipColor = courseColor(live.classLabel!);
      chipLabel = live.classLabel!;
    } else {
      final feed = showClass && live.classId != null
          ? feedCubit.byId(live.classId!)
          : null;
      chipColor = feed == null
          ? Theme.of(context).colorScheme.primary
          : mutedCalendarColor(feed.color);
      chipLabel = feed?.name ?? '';
    }
    final hasChip = chipLabel.isNotEmpty;
    final theme = Theme.of(context);
    final hasEvent = _hasCalendarEvent(live, calendarEvents);
    final timeFormat = DateFormat('h:mm a');
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
      workLine = 'Planned ${timeFormat.format(plannedStart)} – '
          '${timeFormat.format(plannedEnd)}';
    } else if (live.money != null) {
      final actual = moneyActualForNode(live, allNodes);
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
                  'Due ${DateFormat('EEE, MMM d').format(due)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: live.isOverdueAt(now)
                        ? theme.colorScheme.error
                        : null,
                    fontWeight: _isDueToday(due, now)
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Node deleted'),
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
