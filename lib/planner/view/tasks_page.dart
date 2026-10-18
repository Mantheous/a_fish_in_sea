import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../common/undo/undo_bar.dart';
import '../../common/undo/undo_cubit.dart';
import '../../navigation/view/app_drawer.dart';
import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/model/node.dart';
import '../../nodes/service/node_event_link.dart';
import '../../nodes/service/node_progress.dart';
import '../../nodes/view/node_checkbox.dart';
import '../../nodes/view/node_editor.dart';
import '../../nodes/view/node_finish_sheet.dart';
import '../../nodes/view/schedule_sheet.dart';
import '../../nodes/view/timer_edit_sheet.dart';
import '../../finances/bloc/transactions_cubit.dart';
import '../../finances/service/node_transaction_cleanup.dart';
import '../bloc/assignment_estimates_cubit.dart';
import '../bloc/assignment_rules_cubit.dart';
import '../bloc/calendar_cubit.dart';
import '../bloc/feed_cubit.dart';
import '../bloc/tasks_tab_cubit.dart';
import '../bloc/tasks_view_options_cubit.dart';
import '../model/assignment_estimate.dart';
import '../model/assignment_rule.dart';
import '../model/assignment_template.dart';
import '../model/feed.dart';
import '../model/planner_event.dart';
import '../model/task_assignee.dart';
import 'feed_manager.dart';
import 'assignment_rules_sheet.dart';
import 'syllabus_import_sheet.dart';
import 'task_highlight_tint.dart';
import 'tasks_view_filtering.dart';
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

  /// Selection restricted to nodes that still exist, so bulk actions
  /// never reference nodes deleted elsewhere.
  Set<String> _liveSelection(NodeCubit nodes) =>
      _selected.where((id) => nodes.byId(id) != null).toSet();

  void _markSelectedDone() {
    final undoCubit = context.read<UndoCubit>();
    NodeCubit nodes;
    try {
      nodes = context.read<NodeCubit>();
    } catch (_) {
      return;
    }
    CalendarCubit? calendar;
    try {
      calendar = context.read<CalendarCubit>();
    } catch (_) {}
    final ids = _liveSelection(nodes);
    if (ids.isEmpty) {
      _clearSelection();
      return;
    }
    final changed = calendar == null
        ? nodes.setDoneMany(ids, done: true)
        : NodeEventLink.setNodesDone(nodes, calendar, ids, done: true);
    setState(() {
      _selected.clear();
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            changed == 1 ? '1 task marked done' : '$changed tasks marked done',
          ),
          duration: const Duration(seconds: 4),
          // Action snackbars persist forever by default; this one must go.
          persist: false,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: undoCubit.undo,
          ),
        ),
      );
  }

  void _deleteSelected() {
    final undoCubit = context.read<UndoCubit>();
    NodeCubit nodes;
    try {
      nodes = context.read<NodeCubit>();
    } catch (_) {
      return;
    }
    CalendarCubit? calendar;
    try {
      calendar = context.read<CalendarCubit>();
    } catch (_) {}
    final ids = _liveSelection(nodes);
    if (ids.isEmpty) {
      _clearSelection();
      return;
    }
    int removed;
    try {
      removed = deleteNodesAndClearAssignments(
        nodes: nodes,
        transactions: context.read<TransactionsCubit>(),
        alsoTrack: calendar == null ? const [] : [calendar],
        delete: () => calendar == null
            ? nodes.deleteNodes(ids)
            : NodeEventLink.deleteNodesAndUnlink(nodes, calendar, ids),
      );
    } catch (_) {
      removed = calendar == null
          ? nodes.deleteNodes(ids)
          : NodeEventLink.deleteNodesAndUnlink(nodes, calendar, ids);
    }
    setState(() {
      _selected.clear();
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            removed == 1 ? '1 task deleted' : '$removed tasks deleted',
          ),
          duration: const Duration(seconds: 4),
          // Action snackbars persist forever by default; this one must go.
          persist: false,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: undoCubit.undo,
          ),
        ),
      );
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
                  _TodoTab(
                    selected: _selected,
                    selecting: _selecting,
                    onToggleSelection: _toggleSelection,
                    onEnterSelection: _enterSelection,
                    onSelectAll: _selectAll,
                    onDeselectAll: _deselectAll,
                  ),
                  _HomeworkTab(
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

final _timeFormat = DateFormat('h:mm a');
final _dueFormat = DateFormat('EEE, MMM d');

/// Estimate for one assignment: the rule's explicit number, then the
/// learned average for its classified type, then the node's own time
/// target, then a plain hour.
///
/// Both cubits are optional so standalone widget tests (and any future
/// embed of this tile) keep working without them.
AssignmentEstimate _estimateFor(BuildContext context, Node node) {
  var rules = const <AssignmentRule>[];
  var efforts = const <AssignmentTypeEffort>[];
  try {
    rules = context.read<AssignmentRulesCubit>().state;
  } catch (_) {}
  try {
    efforts = context.read<AssignmentEstimatesCubit>().state;
  } catch (_) {}
  return resolveAssignmentEstimate(node: node, rules: rules, efforts: efforts);
}

/// "Est 45m" / "Est 1h 30m, usually 7 PM" for the tile's work line.
String _estimateLine(AssignmentEstimate estimate) {
  final minutes = describeMinutes(estimate.minutes);
  final start = estimate.preferredStartMinute;
  if (start == null) return 'Est ~$minutes';
  return 'Est ~$minutes, ${describeTimeOfDay(start)}';
}

/// Empty state shown when the active view (or a hiding rule) leaves
/// no rows. Offers a way back to the full list.
class _FilteredEmpty extends StatelessWidget {
  final String filterName;

  const _FilteredEmpty({required this.filterName});

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
class _SelectAllRow extends StatelessWidget {
  final bool allSelected;
  final int count;
  final ValueChanged<bool> onChanged;

  const _SelectAllRow({
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

class _TodoTab extends StatelessWidget {
  final Set<String> selected;
  final bool selecting;
  final void Function(String id) onToggleSelection;
  final void Function(String id) onEnterSelection;
  final void Function(Iterable<String> ids) onSelectAll;
  final void Function(Iterable<String> ids) onDeselectAll;

  const _TodoTab({
    required this.selected,
    required this.selecting,
    required this.onToggleSelection,
    required this.onEnterSelection,
    required this.onSelectAll,
    required this.onDeselectAll,
  });

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NodeCubit, List<Node>>(
      builder: (context, nodes) {
        final feedCubit = context.watch<FeedCubit>();
        final nodeCubit = context.read<NodeCubit>();
        final viewOptions = viewOptionsOf(context);
        final now = DateTime.now();
        final tints = taskTintMap(nodeCubit.state, viewOptions, now);
        var open = applyTaskViewOptions(
          feedCubit.visibleNodes(nodeCubit.openNodes),
          viewOptions,
          now,
        );
        if (open.isEmpty) {
          return viewOptions.isFiltering
              ? _FilteredEmpty(filterName: viewOptions.activeFilter.name)
              : const _EmptyTodo();
        }
        // Precompute once per list build (not per tile): calendar link set,
        // feed map, node indexes, and a single `now`. Tiles receive plain
        // data and use `read` — no per-tile full-state watches.
        final calendarState = context.watch<CalendarCubit>().state;
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
        Widget list = ListView.builder(
          itemCount: open.length,
          itemBuilder: (context, index) {
            final node = open[index];
            return _NodeTile(
              node: node,
              showClass: true,
              now: now,
              highlightMatched: tints.containsKey(node.id),
              highlightColorValue: tints[node.id]?.colorValue,
              highlightLabel: tints[node.id]?.label ?? 'Highlighted',
              feedById: feedById,
              nodeById: nodeById,
              indexById: indexes.byId,
              indexByParent: indexes.byParent,
              linkedEventIds: linkedEventIds,
              linkedTaskIds: linkedTaskIds,
              selected: selected.contains(node.id),
              selecting: selecting,
              onToggleSelection: () => onToggleSelection(node.id),
              onEnterSelection: () => onEnterSelection(node.id),
            );
          },
        );
        if (!selecting) return list;
        final allIds = [for (final n in open) n.id];
        final allSelected = allIds.every(selected.contains);
        final count = allIds.where(selected.contains).length;
        return Column(
          children: [
            _SelectAllRow(
              allSelected: allSelected,
              count: count,
              onChanged: (select) =>
                  select ? onSelectAll(allIds) : onDeselectAll(allIds),
            ),
            Expanded(child: list),
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

class _HomeworkTab extends StatefulWidget {
  final Set<String> selected;
  final bool selecting;
  final void Function(String id) onToggleSelection;
  final void Function(String id) onEnterSelection;
  final void Function(Iterable<String> ids) onSelectAll;
  final void Function(Iterable<String> ids) onDeselectAll;

  const _HomeworkTab({
    required this.selected,
    required this.selecting,
    required this.onToggleSelection,
    required this.onEnterSelection,
    required this.onSelectAll,
    required this.onDeselectAll,
  });

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
    final viewOptions = viewOptionsOf(context);
    final now = DateTime.now();
    final tints = taskTintMap(nodeCubit.state, viewOptions, now);
    var imported = applyTaskViewOptions(
      feedCubit.visibleNodes(
        nodeCubit.state.where((n) => n.isHomework).toList(),
      ),
      viewOptions,
      now,
    );
    if (imported.isEmpty) {
      if (viewOptions.isFiltering) {
        return _FilteredEmpty(filterName: viewOptions.activeFilter.name);
      }
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
    // map, shared money indexes, calendar link sets. Sort each
    // group once up front instead of inside the itemBuilder on every
    // rebuild (the old `..sort` mutated the list during build).
    // (`now` is hoisted at the top of build so highlight + filter share
    // one clock reading.)
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
    final groupMeta =
        <String, ({Color color, String name, bool removable})>{};
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
        groupMeta[key] = (
          color: courseColor(key),
          name: key,
          removable: false,
        );
      } else {
        final feed = feedById[key];
        groupMeta[key] = (
          color: feed == null
              ? Theme.of(context).colorScheme.primary
              : mutedCalendarColor(feed.color),
          name: feed?.name ?? 'Unknown class',
          // A classId group with no feed row (re-added while sync was down,
          // then the duplicate feed vanished) has no Settings entry, so this
          // group is the only place its leftover assignments can be removed.
          removable: feed == null && key.isNotEmpty,
        );
      }
    }
    return Column(
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: feedCubit.isSyncing,
          builder: (context, syncing, _) {
            // Repeating-type candidates for the rules entry point. Same
            // inputs as the rules sheet so the badge/banner match what the
            // sheet will show. Cheap (a few hundred nodes at most).
            var unruledRepeating = 0;
            try {
              final rules = context.watch<AssignmentRulesCubit>().state;
              final samples = <TemplateSample>[
                for (final n in nodeCubit.state)
                  if (n.sourceEventId != null &&
                      n.schedule?.due != null &&
                      (n.feedId ?? n.classId ?? '').isNotEmpty)
                    TemplateSample(
                      feedId: (n.feedId ?? n.classId)!,
                      title: n.title,
                      classLabel: n.classLabel,
                      due: n.schedule!.due,
                    ),
              ];
              final rued = {for (final r in rules) r.groupKey};
              unruledRepeating = detectRepeatingGroups(samples)
                  .where(
                    (g) =>
                        g.isRepeating &&
                        !rued.contains('${g.feedId}|${g.templateKey}'),
                  )
                  .length;
            } catch (_) {}
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  dense: true,
                  title: Text(
                    syncing ? 'Syncing…' : 'Assignments by class',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Badge(
                        isLabelVisible: unruledRepeating > 0,
                        label: Text('$unruledRepeating'),
                        child: IconButton(
                          tooltip: 'Repeating assignment rules',
                          icon: const Icon(Icons.tune_outlined),
                          onPressed: () => showAssignmentRules(context),
                        ),
                      ),
                      IconButton(
                        icon: syncing
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh),
                        onPressed: syncing
                            ? null
                            : () => feedCubit.syncAll(force: true),
                      ),
                    ],
                  ),
                ),
                if (unruledRepeating > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                    child: Card(
                      child: ListTile(
                        dense: true,
                        leading: const Icon(Icons.auto_awesome_outlined),
                        title: Text(
                          unruledRepeating == 1
                              ? '1 repeating type detected'
                              : '$unruledRepeating repeating types detected',
                        ),
                        subtitle: const Text(
                          'Weekly quizzes and problem sets can be due '
                          'earlier or later in your plan.',
                        ),
                        trailing: TextButton(
                          onPressed: () => showAssignmentRules(context),
                          child: const Text('View'),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        if (widget.selecting)
          Builder(
            builder: (context) {
              final allIds = [for (final n in imported) n.id];
              final allSelected = allIds.every(widget.selected.contains);
              final count = allIds.where(widget.selected.contains).length;
              return _SelectAllRow(
                allSelected: allSelected,
                count: count,
                onChanged: (select) => select
                    ? widget.onSelectAll(allIds)
                    : widget.onDeselectAll(allIds),
              );
            },
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
                  title: Text(meta.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${groupOpenCount[groupKey]} to do'),
                  trailing: meta.removable
                      ? IconButton(
                          tooltip: 'Remove unknown class',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _confirmRemoveOrphanClass(
                            context,
                            groupKey,
                            classNodes.length,
                          ),
                        )
                      : null,
                  children: [
                    for (final node in classNodes)
                      _NodeTile(
                        node: node,
                        showClass: false,
                        now: now,
                        highlightMatched: tints.containsKey(node.id),
                        highlightColorValue: tints[node.id]?.colorValue,
                        highlightLabel: tints[node.id]?.label ?? 'Highlighted',
                        feedById: feedById,
                        nodeById: nodeById,
                        indexById: indexes.byId,
                        indexByParent: indexes.byParent,
                        linkedEventIds: linkedEventIds,
                        linkedTaskIds: linkedTaskIds,
                        selected: widget.selected.contains(node.id),
                        selecting: widget.selecting,
                        onToggleSelection: () =>
                            widget.onToggleSelection(node.id),
                        onEnterSelection: () =>
                            widget.onEnterSelection(node.id),
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

  /// Removes an "Unknown class" group: its feed entry is gone, so the
  /// assignments and calendar events imported from it can only be deleted
  /// from here.
  Future<void> _confirmRemoveOrphanClass(
    BuildContext context,
    String classId,
    int count,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove unknown class?'),
        content: Text(
          'This class no longer has a feed entry, so its assignments can '
          'only be removed here. Removing deletes '
          '${count == 1 ? '1 assignment' : '$count assignments'} and their '
          'calendar events.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    context.read<FeedCubit>().removeOrphanedClass(classId);
    final undoCubit = context.read<UndoCubit>();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            count == 1 ? 'Removed 1 assignment' : 'Removed $count assignments',
          ),
          duration: const Duration(seconds: 4),
          persist: false,
          action: SnackBarAction(label: 'Undo', onPressed: undoCubit.undo),
        ),
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

/// Readable orange for "due today" cues in either brightness.
Color _dueTodayColor(ThemeData theme) => theme.brightness == Brightness.dark
    ? Colors.orange.shade300
    : Colors.orange.shade800;

class _NodeTile extends StatelessWidget {
  final Node node;
  final bool showClass;

  /// True when a highlight rule matches this node (open, inside the
  /// rule's window). [highlightColorValue] tints the row, or the theme
  /// default when null; [highlightLabel] names the winning rule for
  /// screen readers. Rows due today always glow orange on top.
  final bool highlightMatched;
  final int? highlightColorValue;
  final String highlightLabel;
  // Hoisted per-list data (all optional for backwards compat): when
  // supplied the tile avoids per-tile `watch` subscriptions and O(n) scans.
  final DateTime? now;
  final Map<String, Feed>? feedById;
  final Map<String, Node>? nodeById;
  final Map<String, Node>? indexById;
  final Map<String, List<Node>>? indexByParent;
  final Set<String>? linkedEventIds;
  final Set<String>? linkedTaskIds;
  // Multi-select state. While [selecting], the leading checkbox becomes
  // a selection box and taps toggle selection instead of opening the
  // editor; long-press is what enters selection mode.
  final bool selected;
  final bool selecting;
  final VoidCallback? onToggleSelection;
  final VoidCallback? onEnterSelection;

  const _NodeTile({
    required this.node,
    required this.showClass,
    this.highlightMatched = false,
    this.highlightColorValue,
    this.highlightLabel = 'Highlighted',
    this.now,
    this.feedById,
    this.nodeById,
    this.indexById,
    this.indexByParent,
    this.linkedEventIds,
    this.linkedTaskIds,
    this.selected = false,
    this.selecting = false,
    this.onToggleSelection,
    this.onEnterSelection,
  });
  @override
  Widget build(BuildContext context) {
    final nodeCubit = context.read<NodeCubit>();
    // Fast path: parent already rebuilt on NodeCubit changes, so resolve
    // liveness from the hoisted map instead of subscribing every tile to
    // the full node list (N tiles × full-state subscription + O(n) byId
    // each = O(n²) per edit).
    final live =
        nodeById?[node.id] ?? context.read<NodeCubit>().byId(node.id) ?? node;
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
    final hasEvent =
        _hasCalendarEventFast(
          live,
          linkedEventIds: linkedEventIds,
          linkedTaskIds: linkedTaskIds,
        ) ??
        _hasCalendarEvent(live, context.read<CalendarCubit>().state);
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
      workLine =
          'Planned ${_timeFormat.format(plannedStart)} – '
          '${_timeFormat.format(plannedEnd)}';
    } else if (live.isHomework) {
      // Not placed yet: show what the app expects this to take, and the
      // slot the schedule will default to.
      workLine = _estimateLine(_estimateFor(context, live));
    } else if (live.money != null) {
      final actual = (indexById != null && indexByParent != null)
          ? moneyActualForNodeIndexed(
              live,
              byId: indexById!,
              byParent: indexByParent!,
            )
          : moneyActualForNode(live, context.read<NodeCubit>().state);
      workLine =
          '\$${actual.toStringAsFixed(2)} / \$${live.money!.effectiveTarget.toStringAsFixed(2)}';
    }
    final due = live.schedule?.due;
    // Due today outranks the custom tint: same highlight, hotter color.
    // (A highlighted row is always open — the highlight set is open-only
    // — so no extra status check is needed.)
    final isDueTodayHighlight =
        highlightMatched && due != null && _isDueToday(due, effectiveNow);
    final highlightTextColor = highlightColorValue == null
        ? theme.colorScheme.tertiary
        : Color(highlightColorValue!);
    final tile = ListTile(
      selected: selecting && selected,
      selectedTileColor: theme.colorScheme.secondaryContainer,
      leading: selecting
          ? Checkbox(
              value: selected,
              onChanged: (_) => onToggleSelection?.call(),
            )
          : NodeCheckbox(node: live),
      title: Text(
        live.title,
        style: TextStyle(
          decoration: live.isDone || failed ? TextDecoration.lineThrough : null,
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
                        : isDueTodayHighlight
                        ? _dueTodayColor(theme)
                        : highlightMatched
                        ? highlightTextColor
                        : null,
                    fontWeight:
                        _isDueToday(due, effectiveNow) || highlightMatched
                        ? FontWeight.bold
                        : null,
                  ),
                ),
            ],
          ),
          // Toggl-style: tap a recording/reported line to correct it
          // (move the start while running, edit the interval after).
          if (workLine != null)
            live.isTracking ||
                    (!failed &&
                        live.hasReported &&
                        live.reportedDuration != null)
                ? InkWell(
                    onTap: () =>
                        showEditNodeTimerSheet(context, nodeId: live.id),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
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
                : Text(
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
                        NodeEventLink.startNodeTracking(
                          nodeCubit,
                          context.read<CalendarCubit>(),
                          live.id,
                        );
                      } catch (_) {}
                    }
                  },
          ),
          IconButton(
            tooltip:
                (hasEvent ||
                    live.schedule?.due != null ||
                    (live.schedule?.hasCalendarBlock ?? false))
                ? 'Scheduled — tap to change'
                : 'Schedule',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(),
            icon: Icon(
              Icons.schedule,
              color:
                  (hasEvent ||
                      live.schedule?.due != null ||
                      (live.schedule?.hasCalendarBlock ?? false))
                  ? theme.colorScheme.primary
                  : null,
            ),
            onPressed: () => showScheduleSheet(context, nodeId: live.id),
          ),
          PopupMenuButton<String>(
            padding: EdgeInsets.zero,
            onSelected: (value) {
              if (value == 'edit') {
                showNodeEditor(context, existing: live);
              }
              if (value == 'delete') _delete(context, live);
              if (value == 'schedule') {
                showScheduleSheet(context, nodeId: live.id);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'schedule', child: Text('Schedule…')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
      onTap: selecting
          ? onToggleSelection
          : () => showNodeEditor(context, existing: live),
      onLongPress: selecting ? onToggleSelection : onEnterSelection,
    );
    if (!highlightMatched) return tile;
    // Tinted row plus a colored edge: the winning highlight rule matched
    // this item. Due-today rows keep the hotter orange cue on top.
    return TaskHighlightTint(
      hot: isDueTodayHighlight,
      colorValue: highlightColorValue,
      semanticsLabel: highlightLabel,
      child: tile,
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

  static bool _hasCalendarEvent(Node node, List<PlannerEvent> calendarEvents) {
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

  void _delete(BuildContext context, Node node) {
    final undoCubit = context.read<UndoCubit>();
    final nodes = context.read<NodeCubit>();
    CalendarCubit? calendar;
    try {
      calendar = context.read<CalendarCubit>();
    } catch (_) {}
    TransactionsCubit? transactions;
    try {
      transactions = context.read<TransactionsCubit>();
    } catch (_) {}
    try {
      if (transactions == null) {
        if (calendar == null) {
          nodes.deleteNode(node.id);
        } else {
          NodeEventLink.deleteNodesAndUnlink(nodes, calendar, {node.id});
        }
      } else {
        deleteNodesAndClearAssignments(
          nodes: nodes,
          transactions: transactions,
          delete: () {
            if (calendar == null) {
              nodes.deleteNode(node.id);
            } else {
              NodeEventLink.deleteNodesAndUnlink(nodes, calendar, {node.id});
            }
            return null;
          },
        );
      }
    } catch (_) {
      nodes.deleteNode(node.id);
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
            onPressed: undoCubit.undo,
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
