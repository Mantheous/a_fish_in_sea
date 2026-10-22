import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/tasks_view_options_cubit.dart';
import 'syllabus_import_sheet.dart';

/// Shared pieces of the To-Do and Homework task lists.

/// Empty state shown when the active view (or a hiding rule) leaves
/// no rows. Offers a way back to the full list.
class FilteredTaskEmpty extends StatelessWidget {
  final String filterName;

  const FilteredTaskEmpty({super.key, required this.filterName});

  @override
  Widget build(BuildContext context) {
    final label = switch (filterName) {
      'Today' => 'Nothing due today',
      'Overdue' => 'Nothing overdue',
      'All' => 'Nothing to do!',
      _ => 'No matches for "$filterName"',
    };
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline, size: 48),
          const SizedBox(height: 8),
          Text(label, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Try a different filter, or add a node with +'),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () {
              try {
                final cubit = context.read<TasksViewOptionsCubit>();
                cubit.setActiveFilter('all');
                cubit.disableHidingRules();
              } catch (_) {}
            },
            child: const Text('Show everything'),
          ),
        ],
      ),
    );
  }
}

/// "Select all" header shown above a task list while multi-selecting.
class SelectAllRow extends StatelessWidget {
  final bool allSelected;
  final int count;
  final ValueChanged<bool> onChanged;

  const SelectAllRow({
    super.key,
    required this.allSelected,
    required this.count,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!allSelected),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          children: [
            Checkbox(
              value: allSelected,
              onChanged: (v) => onChanged(v ?? false),
            ),
            const Text('Select all'),
            const Spacer(),
            Text(
              '$count selected',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(width: 16),
          ],
        ),
      ),
    );
  }
}

/// Empty To-Do state: nothing open, plus the syllabus import shortcut.
class EmptyTodoList extends StatelessWidget {
  const EmptyTodoList({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline, size: 48),
          const SizedBox(height: 8),
          Text(
            'Nothing to do!',
            style: Theme.of(context).textTheme.titleMedium,
          ),
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
