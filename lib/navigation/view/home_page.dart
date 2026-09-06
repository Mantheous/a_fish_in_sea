import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/navigation/view/navigation_bar.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/task_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/model/task.dart';
import 'package:a_fish_in_sea/planner/service/task_event_link.dart';
import 'package:a_fish_in_sea/planner/view/task_editor.dart';
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
      bottomNavigationBar: const NavBar(),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showTaskEditor(context),
        child: const Icon(Icons.add),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
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
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Checkbox(
        value: task.done,
        onChanged: (_) => TaskEventLink.toggleTaskDone(
          context.read<TaskCubit>(),
          context.read<CalendarCubit>(),
          task.id,
        ),
      ),
      title: Text(task.title),
      subtitle: Text(
        task.isOverdue
            ? 'Overdue'
            : 'Due today',
        style: theme.textTheme.labelSmall?.copyWith(
          color: task.isOverdue ? theme.colorScheme.error : null,
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
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Checkbox(
        value: task.done,
        onChanged: (_) => TaskEventLink.toggleTaskDone(
          context.read<TaskCubit>(),
          context.read<CalendarCubit>(),
          task.id,
        ),
      ),
      title: Text(task.title),
      subtitle: Text(
        task.due == null
            ? label
            : '$label · due ${formatter.format(task.due!)}',
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}
