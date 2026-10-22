import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../nodes/model/node.dart';
import '../../nodes/view/node_editor.dart';
import '../bloc/tasks_tab_cubit.dart';
import '../bloc/tasks_view_options_cubit.dart';
import '../service/task_bulk_actions.dart';
import 'assignment_rules_sheet.dart';
import 'feed_manager.dart';
import 'syllabus_import_sheet.dart';
import 'homework_task_list.dart';
import 'todo_task_list.dart';
import 'tasks_view_options_sheet.dart';

/// The Tasks page compressed into a side-panel-sized body: the same
/// To-Do / Homework lists, view options, import and bulk actions. Tapping
/// a task hands it to [onTaskTap] (the calendar panel selects the task's
/// calendar event) while the ⋮ menu keeps opening the node editor.
class TasksPanel extends StatefulWidget {
  const TasksPanel({super.key, required this.onTaskTap});

  final ValueChanged<Node> onTaskTap;

  @override
  State<TasksPanel> createState() => _TasksPanelState();
}

class _TasksPanelState extends State<TasksPanel> {
  /// Mirrors the Tasks page tab (0 = To-Do, 1 = Homework) through
  /// [TasksTabCubit], so both surfaces land on the same list.
  int _tab = 0;

  /// Multi-select state, one selection across both tabs — same gestures
  /// and bulk actions as the Tasks page.
  final Set<String> _selected = {};

  bool get _selecting => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    try {
      final i = context.read<TasksTabCubit>().state;
      if (i >= 0 && i <= 1) _tab = i;
    } catch (_) {}
  }

  void _setTab(int index) {
    if (_tab != index) setState(() => _tab = index);
    try {
      context.read<TasksTabCubit>().setTab(index);
    } catch (_) {}
  }

  void _toggleSelection(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _enterSelection(String id) {
    setState(() {
      _selected.add(id);
    });
  }

  void _clearSelection() {
    if (_selected.isEmpty) return;
    setState(() {
      _selected.clear();
    });
  }

  void _selectAll(Iterable<String> ids) {
    setState(() {
      _selected.addAll(ids);
    });
  }

  void _deselectAll(Iterable<String> ids) {
    if (_selected.isEmpty) return;
    setState(() {
      _selected.removeAll(ids);
    });
  }

  void _markSelectedDone() {
    markTaskNodesDone(context, _selected);
    if (!mounted) return;
    setState(() {
      _selected.clear();
    });
  }

  void _deleteSelected() {
    deleteTaskNodes(context, _selected);
    if (!mounted) return;
    setState(() {
      _selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('To-Do')),
                    ButtonSegment(value: 1, label: Text('Homework')),
                  ],
                  selected: {_tab},
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 13)),
                  ),
                  onSelectionChanged: (selection) => _setTab(selection.first),
                ),
              ),
              Builder(
                builder: (buttonContext) {
                  var active = false;
                  try {
                    active = buttonContext
                        .watch<TasksViewOptionsCubit>()
                        .state
                        .hasActiveOptions;
                  } catch (_) {}
                  return Badge(
                    isLabelVisible: active,
                    child: IconButton(
                      tooltip: 'View options',
                      icon: const Icon(Icons.layers_outlined),
                      onPressed: () => showTasksViewOptions(buttonContext),
                    ),
                  );
                },
              ),
              PopupMenuButton<String>(
                tooltip: 'More actions',
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  switch (value) {
                    case 'rules':
                      showAssignmentRules(context);
                    case 'view':
                      showTasksViewOptions(context);
                    case 'syllabus':
                      showSyllabusImport(context);
                    case 'classes':
                      showFeedManager(context);
                  }
                },
                itemBuilder: (menuContext) => const [
                  PopupMenuItem(
                    value: 'rules',
                    child: Text('Repeating assignment rules'),
                  ),
                  PopupMenuItem(
                    value: 'view',
                    child: Text('View options'),
                  ),
                  PopupMenuItem(
                    value: 'syllabus',
                    child: Text('Import from syllabus'),
                  ),
                  PopupMenuItem(
                    value: 'classes',
                    child: Text('Manage classes'),
                  ),
                ],
              ),
              IconButton(
                tooltip: 'New task',
                icon: const Icon(Icons.add),
                onPressed: () => showNodeEditor(context),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: IndexedStack(
            index: _tab,
            sizing: StackFit.expand,
            children: [
              TodoTaskList(
                selected: _selected,
                selecting: _selecting,
                onToggleSelection: _toggleSelection,
                onEnterSelection: _enterSelection,
                onSelectAll: _selectAll,
                onDeselectAll: _deselectAll,
                onTaskTap: widget.onTaskTap,
              ),
              HomeworkTaskList(
                selected: _selected,
                selecting: _selecting,
                onToggleSelection: _toggleSelection,
                onEnterSelection: _enterSelection,
                onSelectAll: _selectAll,
                onDeselectAll: _deselectAll,
                onTaskTap: widget.onTaskTap,
              ),
            ],
          ),
        ),
        if (_selecting)
          Material(
            color: theme.colorScheme.surface,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _selected.length == 1
                              ? '1 selected'
                              : '${_selected.length} selected',
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Clear selection',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close),
                        onPressed: _clearSelection,
                      ),
                      IconButton(
                        tooltip: 'Delete selected',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _deleteSelected,
                      ),
                      const SizedBox(width: 4),
                      FilledButton.icon(
                        onPressed: _markSelectedDone,
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('Mark done'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
