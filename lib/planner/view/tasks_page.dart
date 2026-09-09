import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../common/undo/undo_bar.dart';
import '../../common/undo/undo_cubit.dart';
import '../../goals/bloc/goal_cubit.dart';
import '../../goals/bloc/tag_cubit.dart';
import '../../goals/model/goal.dart';
import '../../navigation/bloc/navigation_cubit.dart';
import '../../navigation/view/app_drawer.dart';
import '../bloc/calendar_cubit.dart';
import '../bloc/calendar_draft_cubit.dart';
import '../bloc/feed_cubit.dart';
import '../bloc/task_cubit.dart';
import '../model/feed.dart';
import '../model/planner_event.dart';
import '../model/task.dart';
import 'feed_manager.dart';
import 'task_checkbox.dart';
import 'task_editor.dart';
import 'task_finish_sheet.dart';

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
          onPressed: () => showTaskEditor(context),
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
    return BlocBuilder<TaskCubit, List<Task>>(
      builder: (context, tasks) {
        final feedCubit = context.watch<FeedCubit>();
        final open = feedCubit.visibleTasks(
          context.read<TaskCubit>().openTasks,
        );
        return ListView(
          children: [
            if (open.isEmpty)
              const _EmptyTodo()
            else
              for (final task in open)
                _TaskTile(task: task, showClass: true),
            const _GoalTasksSection(),
          ],
        );
      },
    );
  }
}

class _GoalTasksSection extends StatelessWidget {
  const _GoalTasksSection();

  @override
  Widget build(BuildContext context) {
    List<Goal> goals;
    try {
      goals = context.watch<GoalCubit>().state;
    } catch (_) {
      return const SizedBox.shrink();
    }
    final shown = goals
        .where((g) =>
            g.type == GoalType.checklist && g.showInTasks && !g.done)
        .toList()
      ..sort((a, b) => a.deadline.compareTo(b.deadline));
    if (shown.isEmpty) return const SizedBox.shrink();
    Map<String, String> tagNames;
    try {
      tagNames = {
        for (final t in context.watch<TagCubit>().state) t.id: t.name
      };
    } catch (_) {
      tagNames = const {};
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('Goals',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        for (final goal in shown)
          ListTile(
            leading: Checkbox(
              value: false,
              onChanged: (_) =>
                  context.read<GoalCubit>().toggleDone(goal.id),
            ),
            title: Text(goal.title),
            subtitle: Text(
              'Goal · due ${DateFormat('EEE, MMM d').format(goal.deadline)}'
              '${goal.tagIds.isEmpty ? '' : ' · ${goal.tagIds.map((id) => tagNames[id] ?? 'tag').join(', ')}'}',
            ),
            trailing: IconButton(
              tooltip: 'Open goal',
              icon: const Icon(Icons.flag_outlined),
              onPressed: () =>
                  context.read<NavigationCubit>().setPage(PlannerPage.goals),
            ),
            onTap: () =>
                context.read<NavigationCubit>().setPage(PlannerPage.goals),
          ),
      ],
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
          Text('Nothing to do!', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Add a task with the + button'),
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
    final taskCubit = context.watch<TaskCubit>();
    final feedCubit = context.watch<FeedCubit>();
    final imported = feedCubit
        .visibleTasks(taskCubit.state.where((t) => t.isImported).toList());
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
    final byClass = <String, List<Task>>{};
    for (final task in imported) {
      final key = task.classLabel ?? task.classId ?? '';
      byClass.putIfAbsent(key, () => []).add(task);
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
              onPressed: syncing ? null : () => feedCubit.syncAll(force: true),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: groupKeys.length,
            itemBuilder: (context, index) {
              final groupKey = groupKeys[index];
              final labeled = !byClass[groupKey]!.every(
                (task) => task.classLabel == null,
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
              final classTasks = byClass[groupKey]!..sort(_compare);
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
                  title: Text(groupName),
                  subtitle: Text(
                    '${classTasks.where((t) => !t.done).length} to do',
                  ),
                  children: [
                    for (final task in classTasks)
                      _TaskTile(task: task, showClass: false),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  static int _compare(Task a, Task b) {
    final aDue = a.due;
    final bDue = b.due;
    if (aDue == null && bDue == null) return 0;
    if (aDue == null) return 1;
    if (bDue == null) return -1;
    return aDue.compareTo(bDue);
  }
}

class _TaskTile extends StatelessWidget {
  final Task task;
  final bool showClass;

  const _TaskTile({required this.task, required this.showClass});
  @override
  Widget build(BuildContext context) {
    final taskCubit = context.read<TaskCubit>();
    final feedCubit = context.watch<FeedCubit>();
    final calendarEvents = context.watch<CalendarCubit>().state;
    final live = context.watch<TaskCubit>().byId(task.id) ?? task;
    final Color chipColor;
    final String chipLabel;
    if (showClass && live.classLabel != null) {
      chipColor = courseColor(live.classLabel!);
      chipLabel = live.classLabel!;
    } else {
      final feed =
          showClass && live.classId != null ? feedCubit.byId(live.classId!) : null;
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
    if (live.failed) {
      workLine = 'Failed';
    } else if (live.isTracking) {
      workLine = 'Recording…';
    } else if (live.hasReported && live.reportedDuration != null) {
      final planned = live.plannedDuration;
      workLine = planned == null
          ? 'Reported ${live.reportedDuration!.inMinutes}m'
          : 'Reported ${live.reportedDuration!.inMinutes}m '
              '(planned ${planned.inMinutes}m)';
    } else if (live.hasPlanned &&
        live.plannedStart != null &&
        live.plannedEnd != null) {
      workLine = 'Planned ${timeFormat.format(live.plannedStart!)} – '
          '${timeFormat.format(live.plannedEnd!)}';
    }
    return ListTile(
      leading: TaskCheckbox(task: live),
      title: Text(
        live.title,
        style: TextStyle(
          decoration: live.done || live.failed ? TextDecoration.lineThrough : null,
          color: live.failed
              ? theme.colorScheme.error
              : live.done
                  ? theme.colorScheme.outline
                  : null,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (hasChip) ...[
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    color: chipColor,
                    shape: BoxShape.circle,
                  ),
                ),
                Text(
                  chipLabel,
                  style: theme.textTheme.labelSmall,
                ),
                const SizedBox(width: 8),
              ],
              if (live.due != null)
                Text(
                  'Due ${DateFormat('EEE, MMM d').format(live.due!)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: live.isOverdue ? theme.colorScheme.error : null,
                    fontWeight:
                        live.isDueToday ? FontWeight.bold : null,
                  ),
                ),
            ],
          ),
          if (workLine != null)
            Text(
              workLine,
              style: theme.textTheme.labelSmall?.copyWith(
                color: live.failed
                    ? theme.colorScheme.error
                    : live.isTracking
                        ? theme.colorScheme.primary
                        : null,
                fontWeight: live.failed || live.isTracking
                    ? FontWeight.w600
                    : null,
              ),
            ),
          if (live.assignees.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: _AssigneeLine(task: live),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: live.isTracking ? 'Stop recording' : 'Start recording',
            icon: Icon(
              live.isTracking ? Icons.stop : Icons.play_arrow,
              color: live.isTracking ? theme.colorScheme.primary : null,
            ),
            onPressed: live.done
                ? null
                : () {
                    if (live.isTracking) {
                      stopTaskAndFinish(context, live.id);
                    } else {
                      try {
                        taskCubit.startTracking(live.id);
                      } catch (_) {}
                    }
                  },
          ),
          IconButton(
            tooltip: hasEvent
                ? 'Event added — tap to add another'
                : 'Add to calendar',
            icon: Icon(
              Icons.event_available,
              color: hasEvent ? theme.colorScheme.primary : null,
            ),
            onPressed: () => _addToCalendar(context, live),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'edit') showTaskEditor(context, existing: live);
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
      onTap: () => showTaskEditor(context, existing: live),
    );
  }

  static bool _hasCalendarEvent(
      Task task, List<PlannerEvent> calendarEvents) {
    final linkedId = task.calendarEventId;
    if (linkedId != null) {
      for (final event in calendarEvents) {
        if (event.id == linkedId) return true;
      }
    }
    for (final event in calendarEvents) {
      if (event.taskId != null && event.taskId == task.id) return true;
    }
    return false;
  }

  void _addToCalendar(BuildContext context, Task task) {
    context.read<CalendarDraftCubit>().requestDraft(
          draftSeedFromTask(task),
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

  void _delete(BuildContext context, Task task) {
    final eventId = task.calendarEventId ?? task.sourceEventId;
    context.read<TaskCubit>().deleteTask(task.id);
    if (eventId != null) {
      try {
        context.read<CalendarCubit>().clearTaskLink(eventId);
      } catch (_) {}
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Task deleted'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => context.read<UndoCubit>().undo(),
        ),
      ),
    );
  }
}

class _AssigneeLine extends StatelessWidget {
  final Task task;

  const _AssigneeLine({required this.task});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = task.assignees.take(3).toList();
    final extra = task.assignees.length - shown.length;
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
