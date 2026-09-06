import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../common/undo/undo_bar.dart';
import '../../common/undo/undo_cubit.dart';
import '../../navigation/bloc/navigation_cubit.dart';
import '../../navigation/view/navigation_bar.dart';
import '../bloc/calendar_cubit.dart';
import '../bloc/calendar_draft_cubit.dart';
import '../bloc/feed_cubit.dart';
import '../bloc/task_cubit.dart';
import '../model/feed.dart';
import '../model/planner_event.dart';
import '../model/task.dart';
import '../service/task_event_link.dart';
import 'feed_manager.dart';
import 'task_editor.dart';

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
        bottomNavigationBar: const NavBar(),
        floatingActionButton: FloatingActionButton(
          onPressed: () => showTaskEditor(context),
          child: const Icon(Icons.add),
        ),
        body: TabBarView(
          children: [
            BlocBuilder<TaskCubit, List<Task>>(
              builder: (context, tasks) {
                final feedCubit = context.watch<FeedCubit>();
                final open = feedCubit.visibleTasks(
                  context.read<TaskCubit>().openTasks,
                );
                if (open.isEmpty) return const _EmptyTodo();
                return ListView.builder(
                  itemCount: open.length,
                  itemBuilder: (context, index) => _TaskTile(
                    task: open[index],
                    showClass: true,
                  ),
                );
              },
            ),
            const _HomeworkTab(),
          ],
        ),
      ),
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

class _HomeworkTab extends StatelessWidget {
  const _HomeworkTab();

  @override
  Widget build(BuildContext context) {
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
            itemCount: byClass.length,
            itemBuilder: (context, index) {
              final groupKey = byClass.keys.elementAt(index);
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
                  initiallyExpanded: true,
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
    final Color chipColor;
    final String chipLabel;
    if (showClass && task.classLabel != null) {
      chipColor = courseColor(task.classLabel!);
      chipLabel = task.classLabel!;
    } else {
      final feed =
          showClass && task.classId != null ? feedCubit.byId(task.classId!) : null;
      chipColor = feed == null
          ? Theme.of(context).colorScheme.primary
          : mutedCalendarColor(feed.color);
      chipLabel = feed?.name ?? '';
    }
    final hasChip = chipLabel.isNotEmpty;
    final theme = Theme.of(context);
    final hasEvent = _hasCalendarEvent(task, calendarEvents);
    return ListTile(
      leading: Checkbox(
        value: task.done,
        onChanged: (_) => TaskEventLink.toggleTaskDone(
          taskCubit,
          context.read<CalendarCubit>(),
          task.id,
        ),
      ),
      title: Text(
        task.title,
        style: TextStyle(
          decoration: task.done ? TextDecoration.lineThrough : null,
          color: task.done ? theme.colorScheme.outline : null,
        ),
      ),
      subtitle: Row(
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
          if (task.due != null)
            Text(
              'Due ${DateFormat('EEE, MMM d').format(task.due!)}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: task.isOverdue ? theme.colorScheme.error : null,
                fontWeight:
                    task.isDueToday ? FontWeight.bold : null,
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: hasEvent
                ? 'Event added — tap to add another'
                : 'Add to calendar',
            icon: Icon(
              Icons.event_available,
              color: hasEvent ? theme.colorScheme.primary : null,
            ),
            onPressed: () => _addToCalendar(context, task),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'edit') showTaskEditor(context, existing: task);
              if (value == 'delete') _delete(context, task);
              if (value == 'calendar') _addToCalendar(context, task);
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
      onTap: () => showTaskEditor(context, existing: task),
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
