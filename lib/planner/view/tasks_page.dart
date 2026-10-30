import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../common/undo/undo_bar.dart';
import '../../navigation/view/app_drawer.dart';
import '../../nodes/view/node_editor.dart';
import '../../nodes/view/quick_record_sheet.dart';
import '../bloc/tasks_tab_cubit.dart';
import '../bloc/tasks_view_options_cubit.dart';
import '../service/task_bulk_actions.dart';
import 'assignment_rules_sheet.dart';
import 'feed_manager.dart';
import 'syllabus_import_sheet.dart';
import 'homework_task_list.dart';
import 'todo_task_list.dart';
import 'tasks_view_options_sheet.dart';

class TasksPage extends StatefulWidget {
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
  State<TasksPage> createState() => _TasksPageState();
}

/// Multi-select lives here so one selection spans both tabs: long-press
/// a task to start selecting, tap to add more, then mark the bunch done
/// (or delete them) from the bottom bar in a single undoable step.
class _TasksPageState extends State<TasksPage> {
  /// Selected node ids. Empty means normal (non-selecting) mode.
  final Set<String> _selected = {};

  bool get _selecting => _selected.isNotEmpty;

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
    return DefaultTabController(
      length: 2,
      initialIndex: TasksPage._initialTab(context),
      child: Builder(
        builder: (context) {
          return Scaffold(
            appBar: AppBar(
              leading: _selecting
                  ? IconButton(
                      tooltip: 'Clear selection',
                      icon: const Icon(Icons.close),
                      onPressed: _clearSelection,
                    )
                  : null,
              title: _selecting
                  ? Text('${_selected.length} selected')
                  : const Text('Tasks'),
              actions: _selecting
                  ? const [UndoRedoActions()]
                  : [
                      IconButton(
                        tooltip: 'Record a new task',
                        icon: const Icon(Icons.fiber_manual_record),
                        onPressed: () => showQuickRecordSheet(context),
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
                              onPressed: () =>
                                  showTasksViewOptions(buttonContext),
                            ),
                          );
                        },
                      ),
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
                      const UndoRedoActions(),
                    ],
              bottom: TabBar(
                onTap: (i) => TasksPage._saveTab(context, i),
                tabs: const [
                  Tab(text: 'To-Do'),
                  Tab(text: 'Homework'),
                ],
              ),
            ),
            drawer: _selecting ? null : const AppDrawer(),
            floatingActionButton: _selecting
                ? null
                : FloatingActionButton(
                    onPressed: () => showNodeEditor(context),
                    child: const Icon(Icons.add),
                  ),
            bottomNavigationBar: _selecting
                ? SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _selected.length == 1
                                  ? '1 selected'
                                  : '${_selected.length} selected',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Delete selected',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: _deleteSelected,
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: _markSelectedDone,
                            icon: const Icon(Icons.check),
                            label: const Text('Mark done'),
                          ),
                        ],
                      ),
                    ),
                  )
                : null,
            body: _TabSaver(
              child: TabBarView(
                children: [
                  TodoTaskList(
                    selected: _selected,
                    selecting: _selecting,
                    onToggleSelection: _toggleSelection,
                    onEnterSelection: _enterSelection,
                    onSelectAll: _selectAll,
                    onDeselectAll: _deselectAll,
                  ),
                  HomeworkTaskList(
                    selected: _selected,
                    selecting: _selecting,
                    onToggleSelection: _toggleSelection,
                    onEnterSelection: _enterSelection,
                    onSelectAll: _selectAll,
                    onDeselectAll: _deselectAll,
                  ),
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
