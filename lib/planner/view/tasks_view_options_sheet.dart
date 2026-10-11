import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/tasks_view_options_cubit.dart';

Future<void> showTasksViewOptions(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => const _TasksViewOptionsSheet(),
  );
}

class _TasksViewOptionsSheet extends StatelessWidget {
  const _TasksViewOptionsSheet();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<TasksViewOptionsCubit>().state;
    final cubit = context.read<TasksViewOptionsCubit>();
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'View options',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                TextButton(
                  onPressed: state.hasActiveOptions ? cubit.clearAll : null,
                  child: const Text('Clear'),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Highlight only adds a cue. A filter hides everything '
              'outside its window — including completed and undated items. '
              'Nothing is added or synced.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                SwitchListTile(
                  value: state.highlightDueThisWeek,
                  onChanged: cubit.setHighlightDueThisWeek,
                  secondary: const Icon(Icons.date_range_outlined),
                  title: const Text('Highlight items due this week'),
                  subtitle: const Text(
                    'Open items due in the rest of the calendar week '
                    '(today through Sunday) get a tinted row and a '
                    'colored edge.',
                  ),
                ),
                const Divider(indent: 16, endIndent: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    'Show only',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SegmentedButton<TasksDueFilter>(
                    segments: const [
                      ButtonSegment(
                        value: TasksDueFilter.all,
                        label: Text('All'),
                      ),
                      ButtonSegment(
                        value: TasksDueFilter.today,
                        label: Text('Today'),
                      ),
                      ButtonSegment(
                        value: TasksDueFilter.overdue,
                        label: Text('Overdue'),
                      ),
                    ],
                    selected: {state.dueFilter},
                    onSelectionChanged: (selected) =>
                        cubit.setDueFilter(selected.single),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Text(
                    switch (state.dueFilter) {
                      TasksDueFilter.all =>
                        'Both lists show everything.',
                      TasksDueFilter.today =>
                        'Only open items due today. Overdue, undated, and '
                        'completed items are hidden until you switch back.',
                      TasksDueFilter.overdue =>
                        'Only open items past their due date. Everything '
                        'else is hidden until you switch back.',
                    },
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
