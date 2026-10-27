import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import 'package:a_fish_in_sea/common/undo/undo_bar.dart';
import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/navigation/view/app_drawer.dart';
import 'package:a_fish_in_sea/nodes/bloc/goals_view_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/auto_goal.dart';
import 'package:a_fish_in_sea/nodes/service/goal_completion.dart';
import 'package:a_fish_in_sea/nodes/service/goal_graph_filter.dart';
import 'package:a_fish_in_sea/nodes/service/goal_progress_snapshot.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/nodes/service/node_legacy_migration.dart';
import 'package:a_fish_in_sea/nodes/service/node_progress.dart';
import 'package:a_fish_in_sea/finances/service/node_transaction_cleanup.dart';
import 'package:a_fish_in_sea/nodes/view/goal_filter_sheet.dart';
import 'package:a_fish_in_sea/nodes/view/goal_picker.dart';
import 'package:a_fish_in_sea/nodes/view/node_checkbox.dart';
import 'package:a_fish_in_sea/nodes/view/node_editor.dart';
import 'package:a_fish_in_sea/nodes/view/node_graph_view.dart';
import 'package:a_fish_in_sea/nodes/view/node_finish_sheet.dart';
import 'package:a_fish_in_sea/nodes/view/task_rollup_tile.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';

final _nodesDateFormat = DateFormat('EEE, MMM d');

class NodesPage extends StatefulWidget {
  const NodesPage({super.key});

  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  // The graph is the landing view. It is the only view that keeps the
  // relationships between goals visible, and filtering collapses
  // non-matching ancestors into path markers instead of deleting them.
  GoalsViewMode _view = GoalsViewMode.graph;
  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _expandAll = false;
  int _expandToken = 0;

  /// Filter selection from the filter menu. Transient UI state only:
  /// never persisted to storage, and cleared by a "Show in goals" reveal.
  GoalGraphFilter _filter = const GoalGraphFilter();

  /// Bumped when the filter changes so the graph re-fits its viewport.
  int _fitToken = 0;

  /// Graph subtrees folded by the user. Null until the graph seeds its
  /// defaults; kept in [GoalsViewCubit] so a tab switch does not re-fold
  /// what the user expanded.
  Set<String>? _collapsedIds;

  /// Keeps this page's view state while another tab is showing. Absent in
  /// widget tests that mount the page without it; the page then simply
  /// starts from defaults.
  GoalsViewCubit? _viewState;
  bool _restoredView = false;

  /// Pending "Show in goals" reveal from [NavigationCubit]: the target is
  /// shown in the All tree with its ancestor chain expanded and itself
  /// highlighted. Transient UI state only — never persisted.
  String? _focusNodeId;
  int _consumedRevision = -1;
  Set<String> _expandedIds = const {};
  final GlobalKey _focusKey = GlobalKey();
  NavigationCubit? _nav;
  VoidCallback? _focusListener;

  @override
  void initState() {
    super.initState();
    // One structural pass per page load: create/adopt the Homework
    // container and one class child per discovered class. Idempotent and
    // additive; feed names only improve the class titles.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Map<String, String> feedNames = const {};
      try {
        feedNames = {
          for (final feed in context.read<FeedCubit>().state)
            feed.id: feed.name,
        };
      } catch (_) {}
      try {
        context.read<NodeCubit>().ensureHomeworkStructure(
          feedNames: feedNames,
        );
      } catch (_) {}
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    NavigationCubit? nav;
    try {
      nav = context.read<NavigationCubit>();
    } catch (_) {
      nav = null;
    }
    if (!identical(nav, _nav)) {
      if (_nav != null && _focusListener != null) {
        _nav!.focusRevision.removeListener(_focusListener!);
      }
      _nav = nav;
      if (nav != null) {
        _focusListener = _onFocusRevision;
        nav.focusRevision.addListener(_onFocusRevision);
      } else {
        _focusListener = null;
      }
    }
    _restoreViewState();
    _onFocusRevision();
  }

  /// Adopts the view state kept by [GoalsViewCubit] (if one is provided)
  /// before the first build, so a tab switch lands on the same view, search,
  /// filter, and folded graph subtrees. A pending "Show in goals" reveal is
  /// applied afterwards and deliberately resets those.
  void _restoreViewState() {
    if (_restoredView) return;
    _restoredView = true;
    try {
      final cubit = context.read<GoalsViewCubit>();
      final saved = cubit.state;
      _viewState = cubit;
      _view = saved.mode;
      _query = saved.query;
      _filter = saved.filter;
      _expandAll = saved.expandAll;
      _collapsedIds = saved.collapsedIds;
      if (saved.query.isNotEmpty) {
        _search.value = TextEditingValue(
          text: saved.query,
          selection: TextSelection.collapsed(offset: saved.query.length),
        );
      }
    } catch (_) {
      _viewState = null;
    }
  }

  /// Saves a snapshot of the page's view state after every change, so the
  /// page can restore itself after another tab replaced it.
  void _persistView() {
    final cubit = _viewState;
    if (cubit == null) return;
    cubit.save(
      GoalsViewState(
        mode: _view,
        query: _query,
        filter: _filter,
        expandAll: _expandAll,
        collapsedIds: _collapsedIds,
      ),
    );
  }

  @override
  void dispose() {
    if (_nav != null && _focusListener != null) {
      _nav!.focusRevision.removeListener(_focusListener!);
    }
    _search.dispose();
    super.dispose();
  }

  /// Applies a fresh [NavigationCubit] focus request: land on the All tree,
  /// expand the target's ancestors, highlight the target, and scroll it
  /// into view. Keyed off [NavigationCubit.focusRevision] (not the page)
  /// so a request while already on Nodes still applies — [Cubit.emit]
  /// suppresses duplicate page states.
  void _onFocusRevision() {
    final nav = _nav;
    if (nav == null || !mounted) return;
    if (nav.focusRevision.value == _consumedRevision) return;
    _consumedRevision = nav.focusRevision.value;
    final id = nav.focusedNodeId;
    if (id == null) {
      if (_focusNodeId == null) return;
      setState(() {
        _focusNodeId = null;
        _expandedIds = const {};
      });
      return;
    }
    Set<String> ancestors = const {};
    try {
      ancestors = ancestorIds(id, context.read<NodeCubit>().state);
    } catch (_) {}
    setState(() {
      _focusNodeId = id;
      _expandedIds = ancestors;
      _view = GoalsViewMode.all;
      _expandToken++;
      _query = '';
      _search.clear();
      _filter = const GoalGraphFilter();
      _fitToken++;
    });
    _persistView();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _focusKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        alignment: 0.5,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    String? topicTitle;
    final topicId = _filter.topicRootId;
    if (topicId != null) {
      try {
        topicTitle = context.read<NodeCubit>().byId(topicId)?.title;
      } catch (_) {}
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Goals'),
        actions: const [UndoRedoActions()],
      ),
      drawer: const AppDrawer(),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showNodeEditor(context),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      labelText: 'Search goals',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) {
                      setState(() => _query = v);
                      _persistView();
                    },
                  ),
                ),
                const SizedBox(width: 4),
                Badge(
                  isLabelVisible: _filter.isActive,
                  label: Text('${_filter.activeCount}'),
                  child: IconButton(
                    key: const ValueKey('goal-filter-button'),
                    tooltip: 'Filter goals',
                    icon: Icon(
                      _filter.isActive
                          ? Icons.filter_alt
                          : Icons.filter_alt_outlined,
                    ),
                    onPressed: _openFilters,
                  ),
                ),
                Tooltip(
                  message: _expandAll ? 'Collapse all' : 'Expand all',
                  child: IconButton(
                    icon: Icon(
                      _expandAll ? Icons.unfold_less : Icons.unfold_more,
                    ),
                    onPressed: () {
                      setState(() {
                        _expandAll = !_expandAll;
                        _expandToken++;
                      });
                      _persistView();
                    },
                  ),
                ),
              ],
            ),
          ),
          _ViewRow(
            view: _view,
            onView: (v) {
              setState(() => _view = v);
              _persistView();
            },
          ),
          GoalFilterSummaryBar(
            filter: _filter,
            topicTitle: topicTitle,
            onChanged: _applyFilter,
          ),
          Expanded(
            child: _NodeBody(
              view: _view,
              query: _query,
              filter: _filter,
              fitToken: _fitToken,
              onClearFilters: () => _applyFilter(const GoalGraphFilter()),
              expandAll: _expandAll,
              expandToken: _expandToken,
              focusNodeId: _focusNodeId,
              expandedIds: _expandedIds,
              focusKey: _focusKey,
              collapsedIds: _collapsedIds,
              onCollapsedChanged: (ids) {
                _collapsedIds = ids;
                _persistView();
              },
            ),
          ),
        ],
      ),
    );
  }

  void _applyFilter(GoalGraphFilter next) {
    setState(() {
      _filter = next;
      _fitToken++;
    });
    _persistView();
  }

  Future<void> _openFilters() async {
    final goals = goalNodes(context.read<NodeCubit>().state);
    final selected = await showGoalFilterSheet(
      context,
      filter: _filter,
      nodes: goals,
      now: DateTime.now(),
      query: _query,
    );
    if (!mounted || selected == null) return;
    _applyFilter(selected);
  }
}

class _ViewRow extends StatelessWidget {
  final GoalsViewMode view;
  final ValueChanged<GoalsViewMode> onView;

  const _ViewRow({required this.view, required this.onView});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          for (final v in GoalsViewMode.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(_label(v)),
                selected: view == v,
                onSelected: (_) => onView(v),
              ),
            ),
        ],
      ),
    );
  }

  static String _label(GoalsViewMode v) => switch (v) {
    GoalsViewMode.leaves => 'Open list',
    GoalsViewMode.all => 'Goal tree',
    GoalsViewMode.automated => 'Automated',
    GoalsViewMode.favorites => 'Favorites',
    GoalsViewMode.graph => 'Graph',
    GoalsViewMode.due => 'Due',
    GoalsViewMode.scheduled => 'Scheduled',
    GoalsViewMode.money => 'Money',
    GoalsViewMode.habits => 'Repeating',
  };
}

class _NodeBody extends StatelessWidget {
  final GoalsViewMode view;
  final String query;
  final GoalGraphFilter filter;
  final int fitToken;
  final bool expandAll;
  final int expandToken;

  /// Clears the filter from the graph's empty state.
  final VoidCallback? onClearFilters;

  /// "Show in goals" reveal: target highlighted in the All tree with
  /// [expandedIds] (its ancestor chain) force-expanded and [focusKey]
  /// scrolled into view. Other views ignore the reveal.
  final String? focusNodeId;
  final Set<String> expandedIds;
  final GlobalKey? focusKey;

  /// Graph fold state carried across page visits; null = seed defaults.
  final Set<String>? collapsedIds;
  final ValueChanged<Set<String>>? onCollapsedChanged;

  const _NodeBody({
    required this.view,
    required this.filter,
    this.fitToken = 0,
    this.onClearFilters,
    this.query = '',
    this.expandAll = false,
    this.expandToken = 0,
    this.focusNodeId,
    this.expandedIds = const {},
    this.focusKey,
    this.collapsedIds,
    this.onCollapsedChanged,
  });

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NodeCubit, List<Node>>(
      builder: (context, nodes) {
        // Goal tree only: homework imports and calendar links live in
        // Tasks/Calendar, never auto-fill this page. Shared with Home's
        // favorite rows: one snapshot builder keeps the same goal at the
        // same percentage on both surfaces.
        final now = DateTime.now();
        final snapshot = buildGoalProgressSnapshot(
          nodes: nodes,
          transactions: context.watch<TransactionsCubit>().state,
          now: now,
        );
        final goals = snapshot.goals;
        if (goals.isEmpty) return const _EmptyNodes();
        final txnAmounts = snapshot.txnAmountsById;
        final autoReadings = snapshot.autoReadings;
        final metricReadings = snapshot.metricReadings;
        final completion = snapshot.completion;
        final progress = snapshot.progress;
        final projection = filterGoalGraph(
          nodes: goals,
          now: now,
          filter: filter,
          query: query,
        );
        // A filter is graph-shaped: lists keep only the matches (the
        // compact path markers belong to the graph). Plain search keeps
        // its old matches + ancestors + descendants shape.
        final visible = projection.filterActive
            ? projection.matchedIds
            : (projection.active ? projection.visibleIds : null);
        List<Node> matching(List<Node> items) => visible == null
            ? items
            : items.where((n) => visible.contains(n.id)).toList();
        // Hoisted once per body build (not per tile): shared DAG indexes,
        // liveness map, and one homework-ahead evaluation (the old code
        // re-ran it O(n) per rule tile).
        final indexes = buildNodeIndexes(goals);
        final nodeById = indexes.byId;
        final byParent = indexes.byParent;
        HomeworkAheadResult? homeworkAhead;
        HomeworkAheadResult getHomeworkAhead() => homeworkAhead ??=
            evaluateHomeworkAhead(all: nodes, now: now, horizonDays: 3);
        Widget flatList(List<Node> items) {
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 80),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final n = items[index];
              return _NodeTile(
                node: n,
                nodes: goals,
                progress: progress,
                txnAmounts: txnAmounts,
                autoReadings: autoReadings,
                metricReadings: metricReadings,
                completion: completion,
                depth: 0,
                flat: true,
                visible: visible,
                expandAll: expandAll,
                expandToken: expandToken,
                nodeById: nodeById,
                byParent: byParent,
                now: now,
                homeworkAhead: getHomeworkAhead(),
              );
            },
          );
        }

        switch (view) {
          case GoalsViewMode.leaves:
            final items = matching(leafNodes(nodes));
            if (items.isEmpty) {
              return const Center(child: Text('No leaf nodes.'));
            }
            return flatList(items);
          case GoalsViewMode.all:
            return _NodeTree(
              nodes: goals,
              progress: progress,
              txnAmounts: txnAmounts,
              autoReadings: autoReadings,
              metricReadings: metricReadings,
              completion: completion,
              visible: visible,
              expandAll: expandAll,
              expandToken: expandToken,
              nodeById: nodeById,
              byParent: byParent,
              now: now,
              homeworkAhead: getHomeworkAhead(),
              focusNodeId: focusNodeId,
              expandedIds: expandedIds,
              focusKey: focusKey,
            );
          case GoalsViewMode.automated:
            final items = matching(
              goals.where((n) => n.isAutomatedGoal || n.isTemplate).toList(),
            );
            if (items.isEmpty) {
              return const Center(
                child: Text(
                  'No automated goals yet.\n'
                  'Edit a goal and turn on Automated goal or Repeats.',
                  textAlign: TextAlign.center,
                ),
              );
            }
            return flatList(items);
          case GoalsViewMode.favorites:
            final items = matching(goals.where((n) => n.isFavorite).toList());
            if (items.isEmpty) {
              return const Center(
                child: Text(
                  'No favorite goals yet.\nStar a goal to pin it here.',
                  textAlign: TextAlign.center,
                ),
              );
            }
            return flatList(items);
          case GoalsViewMode.graph:
            String? topicTitle;
            final topicId = filter.topicRootId;
            if (topicId != null) {
              for (final node in goals) {
                if (node.id == topicId) {
                  topicTitle = node.title;
                  break;
                }
              }
            }
            return NodeGraphView(
              nodes: goals,
              progress: progress,
              visibleIds: projection.active ? projection.visibleIds : null,
              contextIds: projection.contextIds,
              matchedIds: projection.active ? projection.matchedIds : const {},
              filterActive: projection.filterActive,
              filterSummary: projection.filterActive
                  ? goalFilterSummary(filter, topicTitle: topicTitle)
                  : null,
              fitToken: fitToken,
              expandAll: expandAll,
              expandToken: expandToken,
              collapsedIds: collapsedIds,
              onCollapsedChanged: onCollapsedChanged,
              onClearFilters: onClearFilters,
            );
          case GoalsViewMode.due:
            final queue = matching(priorityQueue(goals, now));
            if (queue.isEmpty) {
              return const Center(child: Text('Nothing due.'));
            }
            return flatList(queue);
          case GoalsViewMode.scheduled:
            final items = matching(calendarNodes(goals));
            if (items.isEmpty) {
              return const Center(child: Text('Nothing scheduled.'));
            }
            return flatList(items);
          case GoalsViewMode.money:
            final items = matching(ledgerNodes(goals))
              ..sort((a, b) => _nodeDate(a).compareTo(_nodeDate(b)));
            if (items.isEmpty) {
              return const Center(child: Text('No money nodes yet.'));
            }
            return flatList(items);
          case GoalsViewMode.habits:
            final items = matching(goals.where((n) => n.isTemplate).toList());
            if (items.isEmpty) {
              return const Center(
                child: Text(
                  'No repeating templates yet.\nEnable Repeats in the editor.',
                ),
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.only(bottom: 80),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final n = items[index];
                return _NodeTile(
                  node: n,
                  nodes: goals,
                  progress: progress,
                  txnAmounts: txnAmounts,
                  autoReadings: autoReadings,
                  metricReadings: metricReadings,
                  completion: completion,
                  depth: 0,
                  flat: false,
                  visible: visible,
                  expandAll: expandAll,
                  expandToken: expandToken,
                  nodeById: nodeById,
                  byParent: byParent,
                  now: now,
                  homeworkAhead: getHomeworkAhead(),
                );
              },
            );
        }
      },
    );
  }

  static DateTime _nodeDate(Node n) =>
      n.schedule?.due ??
      n.schedule?.start ??
      n.schedule?.end ??
      DateTime.fromMillisecondsSinceEpoch(0);
}

class _NodeTree extends StatelessWidget {
  final List<Node> nodes;
  final Map<String, double> progress;
  final Map<String, double> txnAmounts;
  final Map<String, AutoGoalReading> autoReadings;
  final Map<String, GoalMetricsReading> metricReadings;
  final Map<String, GoalCompletion> completion;
  final Map<String, Node>? nodeById;
  final Map<String, List<Node>>? byParent;
  final DateTime? now;
  final HomeworkAheadResult? homeworkAhead;
  final Set<String>? visible;
  final bool expandAll;
  final int expandToken;
  final String? focusNodeId;
  final Set<String> expandedIds;
  final GlobalKey? focusKey;

  const _NodeTree({
    required this.nodes,
    required this.progress,
    required this.txnAmounts,
    this.autoReadings = const {},
    this.metricReadings = const {},
    this.completion = const {},
    this.nodeById,
    this.byParent,
    this.now,
    this.homeworkAhead,
    this.visible,
    this.expandAll = false,
    this.expandToken = 0,
    this.focusNodeId,
    this.expandedIds = const {},
    this.focusKey,
  });

  @override
  Widget build(BuildContext context) {
    final inView = visible == null
        ? nodes
        : nodes.where((n) => visible!.contains(n.id)).toList();
    if (inView.isEmpty) {
      return const Center(child: Text('No goals match the search.'));
    }
    final visibleIds = visible ?? {for (final n in nodes) n.id};
    // Filtered roots: visible nodes with no visible parent.
    final roots =
        inView
            .where((n) => n.parentIds.where(visibleIds.contains).isEmpty)
            .toList()
          ..sort(_compareRoots);
    if (roots.isEmpty) {
      // DAG cycle fallback (shouldn't happen): show everything flat.
      return ListView.builder(
        padding: const EdgeInsets.only(bottom: 80),
        itemCount: inView.length,
        itemBuilder: (context, index) {
          final n = inView[index];
          return _NodeTile(
            node: n,
            nodes: nodes,
            progress: progress,
            txnAmounts: txnAmounts,
            autoReadings: autoReadings,
            metricReadings: metricReadings,
            completion: completion,
            depth: 0,
            flat: true,
            visible: visible,
            expandAll: expandAll,
            expandToken: expandToken,
            nodeById: nodeById,
            byParent: byParent,
            now: now,
            homeworkAhead: homeworkAhead,
            focusNodeId: focusNodeId,
            focusKey: focusKey,
          );
        },
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80),
      itemCount: roots.length,
      itemBuilder: (context, index) {
        final n = roots[index];
        return _NodeTile(
          node: n,
          nodes: nodes,
          progress: progress,
          txnAmounts: txnAmounts,
          autoReadings: autoReadings,
          metricReadings: metricReadings,
          completion: completion,
          depth: 0,
          flat: false,
          visited: {n.id},
          visible: visible,
          expandAll: expandAll,
          expandToken: expandToken,
          nodeById: nodeById,
          byParent: byParent,
          now: now,
          homeworkAhead: homeworkAhead,
          focusNodeId: focusNodeId,
          expandedIds: expandedIds,
          focusKey: focusKey,
        );
      },
    );
  }

  static int _compareRoots(Node a, Node b) {
    final aDue = a.schedule?.due;
    final bDue = b.schedule?.due;
    if (aDue == null && bDue == null) {
      return a.createdAt.compareTo(b.createdAt);
    }
    if (aDue == null) return 1;
    if (bDue == null) return -1;
    return aDue.compareTo(bDue);
  }
}

class _NodeTile extends StatelessWidget {
  final Node node;
  final List<Node> nodes;
  final Map<String, double> progress;
  final Map<String, double> txnAmounts;
  final Map<String, AutoGoalReading> autoReadings;
  final Map<String, GoalMetricsReading> metricReadings;
  final Map<String, GoalCompletion> completion;
  final int depth;
  final bool flat;
  final Set<String> visited;
  // Hoisted per-list data: when supplied the tile skips per-tile watches,
  // map rebuilds, and repeated rule evaluations.
  final Map<String, Node>? nodeById;
  final Map<String, List<Node>>? byParent;
  final DateTime? now;
  final HomeworkAheadResult? homeworkAhead;
  final Set<String>? visible;
  final bool expandAll;
  final int expandToken;

  /// Reveal target from "Show in goals": this tile is highlighted when its
  /// id matches, and [expandedIds] (the target's ancestor chain)
  /// force-expands parents. [focusKey] is attached to the target for the
  /// post-frame scroll into view.
  final String? focusNodeId;
  final Set<String> expandedIds;
  final GlobalKey? focusKey;

  const _NodeTile({
    required this.node,
    required this.nodes,
    required this.progress,
    required this.txnAmounts,
    this.autoReadings = const {},
    this.metricReadings = const {},
    this.completion = const {},
    required this.depth,
    required this.flat,
    this.visited = const {},
    this.nodeById,
    this.byParent,
    this.now,
    this.homeworkAhead,
    this.visible,
    this.expandAll = false,
    this.expandToken = 0,
    this.focusNodeId,
    this.expandedIds = const {},
    this.focusKey,
  });

  @override
  Widget build(BuildContext context) {
    // Parent BlocBuilder already rebuilds on NodeCubit changes, so resolve
    // liveness from the hoisted map instead of subscribing every tile to
    // the full list (which was O(n²) + full-tree rebuild per edit).
    final live = nodeById?[node.id] ?? node;
    final kids = flat
        ? const <Node>[]
        : (_children(live)..sort((a, b) => _compareKids(a, b)));
    final goalKids = <Node>[];
    final taskKids = <Node>[];
    for (final kid in kids) {
      if (kid.isTask && !_hasChildren(kid)) {
        taskKids.add(kid);
      } else {
        goalKids.add(kid);
      }
    }
    final value = progress[live.id] ?? 0;
    final theme = Theme.of(context);
    final subtitle = _subtitle(
      context,
      live,
      value,
      kids.length,
      metricReadings[live.id],
      completion[live.id],
    );
    final focused = live.id == focusNodeId;
    Widget wrapFocus(Widget child) {
      if (!focused) return child;
      // Material (not ColoredBox): ListTile paints its background and ink
      // on the nearest Material, which a plain color wrapper would hide.
      return Material(
        key: focusKey,
        color: theme.colorScheme.secondaryContainer,
        child: child,
      );
    }
    final tile = ListTile(
      contentPadding: EdgeInsets.only(left: 16 + depth * 20, right: 8),
      leading: _leading(context, live, completion[live.id]),
      title: Text(
        live.title,
        style: TextStyle(
          decoration: live.isDone || live.status == NodeStatus.failed
              ? TextDecoration.lineThrough
              : null,
          color: live.status == NodeStatus.failed
              ? theme.colorScheme.error
              : live.isDone
              ? theme.colorScheme.outline
              : null,
        ),
      ),
      subtitle: _subtitleWidget(context, subtitle, value, live.isUnbounded),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: _trailingActions(context, live, theme),
      ),
      onTap: () => showNodeEditor(context, existing: live),
    );
    if (kids.isEmpty) return wrapFocus(tile);
    return wrapFocus(
      _ParentTile(
        key: ValueKey('${live.id}:$expandToken:$expandAll'),
        tilePadding: EdgeInsets.only(left: 16 + depth * 20, right: 8),
        leading: _leading(context, live, completion[live.id]),
        title: Text(
          live.title,
          style: TextStyle(
            decoration: live.isDone || live.status == NodeStatus.failed
                ? TextDecoration.lineThrough
                : null,
            color: live.status == NodeStatus.failed
                ? theme.colorScheme.error
                : live.isDone
                ? theme.colorScheme.outline
                : null,
          ),
        ),
        subtitle: _subtitleWidget(context, subtitle, value, live.isUnbounded),
        trailingActions: _trailingActions(context, live, theme),
        initiallyExpanded: expandAll || expandedIds.contains(live.id),
        expandToken: expandToken,
        onTap: () => showNodeEditor(context, existing: live),
        children: [
          for (final k in goalKids)
            _NodeTile(
              node: k,
              nodes: nodes,
              progress: progress,
              txnAmounts: txnAmounts,
              autoReadings: autoReadings,
              metricReadings: metricReadings,
              completion: completion,
              depth: depth + 1,
              flat: false,
              visited: {...visited, k.id},
              visible: visible,
              expandAll: expandAll,
              expandToken: expandToken,
              nodeById: nodeById,
              byParent: byParent,
              now: now,
              homeworkAhead: homeworkAhead,
              focusNodeId: focusNodeId,
              expandedIds: expandedIds,
              focusKey: focusKey,
            ),
          if (taskKids.isNotEmpty)
            TaskRollupTile(
              tilePadding: EdgeInsets.only(
                left: 16 + (depth + 1) * 20,
                right: 8,
              ),
              openCount: taskKids.where((n) => n.isOpen).length,
              doneCount: taskKids.where((n) => n.isDone).length,
              initiallyExpanded: expandAll,
              expandToken: expandToken,
              children: [
                for (final k in taskKids)
                  _NodeTile(
                    node: k,
                    nodes: nodes,
                    progress: progress,
                    txnAmounts: txnAmounts,
                    autoReadings: autoReadings,
                    metricReadings: metricReadings,
                    completion: completion,
                    depth: depth + 2,
                    flat: true,
                    visible: visible,
                    expandAll: expandAll,
                    expandToken: expandToken,
                    nodeById: nodeById,
                    byParent: byParent,
                    now: now,
                    homeworkAhead: homeworkAhead,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  bool _hasChildren(Node node) {
    final map = byParent;
    if (map != null) return (map[node.id] ?? const <Node>[]).isNotEmpty;
    return nodes.any((n) => n.parentIds.contains(node.id));
  }

  /// Action buttons shared by leaf rows ([ListTile]) and parent rows
  /// ([_ParentTile]): record start/stop, Add subgoal, and the overflow
  /// menu. Parent rows previously had no trailing at all, which hid the
  /// Add subgoal button (and the rest) on every goal with children.
  /// Unbounded goals get no tracking buttons and no toggle/fail items:
  /// they are ongoing directions, never completed.
  List<Widget> _trailingActions(
    BuildContext context,
    Node live,
    ThemeData theme,
  ) {
    return [
      IconButton(
        tooltip: live.isFavorite ? 'Unstar' : 'Star',
        icon: Icon(
          live.isFavorite ? Icons.star : Icons.star_border,
          color: live.isFavorite ? theme.colorScheme.primary : null,
        ),
        onPressed: () => context.read<NodeCubit>().toggleFavorite(live.id),
      ),
      if (!live.isUnbounded && live.isTracking)
        IconButton(
          tooltip: 'Stop recording',
          icon: Icon(Icons.stop, color: theme.colorScheme.primary),
          onPressed: () => stopNodeAndFinish(context, live.id),
        )
      else if (!live.isUnbounded && !live.isDone)
        IconButton(
          tooltip: 'Start recording',
          icon: const Icon(Icons.play_arrow),
          onPressed: () {
            try {
              NodeEventLink.startNodeTracking(
                context.read<NodeCubit>(),
                context.read<CalendarCubit>(),
                live.id,
              );
            } catch (_) {}
          },
        ),
      IconButton(
        tooltip: 'Add subgoal',
        icon: const Icon(Icons.add_task_outlined),
        onPressed: () => _onMenu(context, live, 'subgoal'),
      ),
      PopupMenuButton<String>(
        tooltip: 'More actions',
        icon: const Icon(Icons.more_vert),
        onSelected: (choice) => _onMenu(context, live, choice),
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'subgoal', child: Text('Add subgoal')),
          const PopupMenuItem(value: 'edit', child: Text('Edit')),
          const PopupMenuItem(
            value: 'add-child',
            child: Text('Add child step'),
          ),
          const PopupMenuItem(
            value: 'breakdown',
            child: Text('Auto-breakdown into steps…'),
          ),
          const PopupMenuItem(
            value: 'duplicate',
            child: Text('Duplicate subtree'),
          ),
          if (!live.isUnbounded)
            const PopupMenuItem(value: 'toggle', child: Text('Toggle done')),
          if (!live.isUnbounded)
            PopupMenuItem(
              value: 'fail',
              child: Text(
                live.status == NodeStatus.failed
                    ? 'Unmark failed'
                    : 'Mark failed',
              ),
            ),
          if (live.isTemplate)
            const PopupMenuItem(
              value: 'generate',
              child: Text('Generate schedule'),
            ),
          const PopupMenuItem(
            value: 'assign-event',
            child: Text('Assign repeating event…'),
          ),
          if (live.money != null) ...[
            const PopupMenuItem(value: 'subdivide', child: Text('Subdivide')),
            if (live.money!.isRecurring)
              const PopupMenuItem(
                value: 'rollover',
                child: Text('Rollover period'),
              ),
          ],
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    ];
  }

  List<Node> _children(Node parent) {
    final parentMap = byParent;
    if (parentMap != null) {
      final out = <Node>[];
      for (final n in parentMap[parent.id] ?? const <Node>[]) {
        if (visible != null && !visible!.contains(n.id)) continue;
        if (!visited.contains(n.id)) out.add(n);
      }
      return out;
    }
    final byId = {for (final n in nodes) n.id: n};
    final filter = visible;
    final out = <Node>[];
    for (final n in nodes) {
      if (filter != null && !filter.contains(n.id)) continue;
      if (n.parentIds.contains(parent.id) &&
          !visited.contains(n.id) &&
          byId.containsKey(n.id)) {
        out.add(n);
      }
    }
    return out;
  }

  static int _compareKids(Node a, Node b) {
    final aDue = a.schedule?.due;
    final bDue = b.schedule?.due;
    if (aDue == null && bDue == null) {
      return a.createdAt.compareTo(b.createdAt);
    }
    if (aDue == null) return 1;
    if (bDue == null) return -1;
    return aDue.compareTo(bDue);
  }

  Widget _leading(
    BuildContext context,
    Node live,
    GoalCompletion? completion,
  ) {
    if (live.isUnbounded) {
      return const Tooltip(
        message: 'Unbounded goal — ongoing, no checkbox',
        child: Icon(Icons.all_inclusive),
      );
    }
    // Metric goals and containers derive completion; only checklist leaves
    // keep an editable checkbox.
    if (completion?.derived == true) {
      final complete = completion!.complete;
      return Tooltip(
        message: live.isClassNode
            ? (complete
                  ? 'Class complete — all work done'
                  : 'Class — completes when all work is done')
            : live.hasMetrics
            ? (complete
                  ? 'Complete — all metrics pass'
                  : 'Incomplete — not all metrics pass')
            : (complete
                  ? 'Complete — all sub-work done'
                  : 'Completes when all sub-work is done'),
        child: Icon(
          complete ? Icons.check_circle : Icons.radio_button_unchecked,
          color: complete
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outline,
        ),
      );
    }
    if (live.isAutomatedGoal) {
      return const Tooltip(
        message: 'Automated goal — measured from your data',
        child: Icon(Icons.auto_graph),
      );
    }
    if (live.isClassNode) {
      return const Tooltip(
        message: 'Class node',
        child: Icon(Icons.school_outlined),
      );
    }
    if (live.isTemplate) {
      return const Icon(Icons.repeat_outlined);
    }
    if (live.rule != null && live.rule!.kind != NodeRuleKind.none) {
      return const Icon(Icons.auto_awesome_outlined);
    }
    if (live.money != null) {
      return const Icon(Icons.savings_outlined);
    }
    if (live.effort != null || live.hasCalendarBlock) {
      return const Icon(Icons.timer_outlined);
    }
    if (live.anki != null) {
      return const Icon(Icons.school_outlined);
    }
    return NodeCheckbox(node: live);
  }

  /// Subtitle area: unbounded goals show text only (no bar, no percent);
  /// everything else keeps the progress bar underneath.
  Widget _subtitleWidget(
    BuildContext context,
    String subtitle,
    double value,
    bool unbounded,
  ) {
    final theme = Theme.of(context);
    if (unbounded) {
      return Text(subtitle, style: theme.textTheme.labelSmall);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(subtitle, style: theme.textTheme.labelSmall),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: value),
      ],
    );
  }

  String _subtitle(
    BuildContext context,
    Node live,
    double value,
    int childCount,
    GoalMetricsReading? metricReading,
    GoalCompletion? completion,
  ) {
    // Unbounded goals never show dates, targets, or a percent — just the
    // ongoing marker plus how many concrete steps hang underneath.
    if (live.isUnbounded) {
      final parts = <String>['unbounded'];
      if (childCount > 0) {
        parts.add('$childCount step${childCount == 1 ? '' : 's'}');
      }
      return parts.join(' · ');
    }
    final effectiveNow = now ?? DateTime.now();
    final parts = <String>[];
    if (live.isClassNode) {
      parts.add('class');
      final sources = live.classFacet?.sources.length ?? 0;
      if (sources > 0) {
        parts.add('$sources feed${sources == 1 ? '' : 's'}');
      }
    }
    if (childCount > 0) {
      parts.add('$childCount step${childCount == 1 ? '' : 's'}');
    }
    final primary = metricReading?.primary;
    if (primary != null) {
      parts.add(metricReading!.summary);
      if (primary.facet.metric != AutoMetric.allDone) {
        parts.add(primary.windowLabel);
      }
      if (metricReading.readings.length == 1 &&
          primary.facet.metric != AutoMetric.allDone &&
          primary.matchedLabel.isNotEmpty) {
        parts.add(primary.matchedLabel);
      }
      if (metricReading.satisfied) parts.add('complete ✓');
    } else if (live.isAutomatedGoal) {
      parts.add('automated goal');
    } else if (live.money != null) {
      final m = live.money!;
      final actual = byParent != null && nodeById != null
          ? moneyActualForNodeIndexed(
              live,
              byId: nodeById!,
              byParent: byParent!,
              txnAmountsById: txnAmounts,
            )
          : moneyActualForNode(live, nodes, txnAmountsById: txnAmounts);
      parts.add(
        '\$${actual.toStringAsFixed(2)} / \$${m.effectiveTarget.toStringAsFixed(2)}',
      );
    } else if (live.effort != null) {
      final actual = byParent != null && nodeById != null
          ? timeActualForNodeIndexed(live, byId: nodeById!, byParent: byParent!)
          : timeActualForNode(live, nodes);
      parts.add(
        '${actual.toStringAsFixed(0)}m / ${live.effort!.targetMinutes}m',
      );
    } else if (live.anki != null) {
      final actual = byParent != null && nodeById != null
          ? ankiActualForNodeIndexed(live, byId: nodeById!, byParent: byParent!)
          : ankiActualForNode(live, nodes);
      final deck = live.anki!.deckName == null
          ? ''
          : ' (${live.anki!.deckName})';
      parts.add(
        '${actual.toStringAsFixed(0)} / ${live.anki!.targetReviews} reviews$deck',
      );
    }
    if (live.rule != null && live.rule!.kind == NodeRuleKind.homeworkAhead) {
      final r =
          homeworkAhead ??
          evaluateHomeworkAhead(
            all: context.read<NodeCubit>().state,
            now: effectiveNow,
            horizonDays: live.rule!.horizonDays,
          );
      parts.add(
        r.satisfied
            ? 'ahead ✓ (${r.dueSoon.length} due soon)'
            : '${r.doneCount}/${r.dueSoon.length} ready',
      );
    }
    final due = live.schedule?.due;
    if (due != null) {
      final label = live.isOverdueAt(effectiveNow)
          ? 'overdue'
          : 'due ${_nodesDateFormat.format(due)}';
      parts.add(label);
    } else if (live.hasCalendarBlock) {
      parts.add('scheduled ${_nodesDateFormat.format(live.schedule!.start!)}');
    }
    if (live.isInstance) parts.add('instance');
    if ((live.schedule?.isFixed ?? false) || (live.money?.isFixed ?? false)) {
      parts.add('fixed');
    }
    if (completion?.derived == true &&
        completion!.complete &&
        !(metricReading?.satisfied ?? false)) {
      parts.add('all work done ✓');
    }
    if (metricReading == null) parts.add('${(value * 100).round()}%');
    if (parts.isEmpty) return 'note';
    return parts.join(' · ');
  }

  void _onMenu(BuildContext context, Node live, String choice) {
    final cubit = context.read<NodeCubit>();
    switch (choice) {
      case 'subgoal':
        showNodeEditor(context, initialParentIds: [live.id]);
      case 'edit':
        showNodeEditor(context, existing: live);
      case 'add-child':
        showNodeEditor(context, initialParentIds: [live.id]);
      case 'breakdown':
        _promptBreakdown(context, live);
      case 'duplicate':
        final error = cubit.duplicateSubtree(live.id);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error ?? 'Duplicated “${live.title}”')),
        );
      case 'toggle':
        try {
          NodeEventLink.toggleNodeDone(
            cubit,
            context.read<CalendarCubit>(),
            live.id,
          );
        } catch (_) {
          cubit.toggleDone(live.id);
        }
      case 'fail':
        try {
          NodeEventLink.setNodeFailed(
            cubit,
            context.read<CalendarCubit>(),
            live.id,
            live.status != NodeStatus.failed,
          );
        } catch (_) {
          cubit.setStatus(
            live.id,
            live.status == NodeStatus.failed
                ? NodeStatus.open
                : NodeStatus.failed,
          );
        }
      case 'generate':
        final made = cubit.generateInstances(
          templateId: live.id,
          from: DateTime.now(),
          horizon: DateTime.now().add(const Duration(days: 365)),
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Generated $made instance(s)')));
      case 'assign-event':
        _assignRepeatingEvent(context, live);
      case 'subdivide':
        _promptSubdivide(context, live);
      case 'rollover':
        final spent = byParent != null && nodeById != null
            ? moneyActualForNodeIndexed(
                live,
                byId: nodeById!,
                byParent: byParent!,
                txnAmountsById: txnAmounts,
              )
            : moneyActualForNode(live, nodes, txnAmountsById: txnAmounts);
        cubit.applyRollover(live.id, spent);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rolled over to next period')),
        );
      case 'delete':
        final undoCubit = context.read<UndoCubit>();
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
              cubit.deleteNode(live.id);
            } else {
              NodeEventLink.deleteNodesAndUnlink(cubit, calendar, {live.id});
            }
          } else {
            deleteNodesAndClearAssignments(
              nodes: cubit,
              transactions: transactions,
              delete: () {
                if (calendar == null) {
                  cubit.deleteNode(live.id);
                } else {
                  NodeEventLink.deleteNodesAndUnlink(cubit, calendar, {
                    live.id,
                  });
                }
                return null;
              },
            );
          }
        } catch (_) {
          cubit.deleteNode(live.id);
        }
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: const Text('Node deleted'),
              duration: const Duration(seconds: 4),
              // Action snackbars persist forever by default; this one must go.
              persist: false,
              action: SnackBarAction(label: 'Undo', onPressed: undoCubit.undo),
            ),
          );
    }
  }

  void _assignRepeatingEvent(BuildContext context, Node live) async {
    final messenger = ScaffoldMessenger.of(context);
    final undoCubit = context.read<UndoCubit>();
    CalendarCubit calendar;
    NodeCubit nodes;
    try {
      calendar = context.read<CalendarCubit>();
      nodes = context.read<NodeCubit>();
    } catch (_) {
      return;
    }
    final event = await showRepeatingEventPicker(context);
    if (event == null || !context.mounted) return;
    // The tile's snapshot may be stale; the goal itself is what matters.
    final goal = nodes.byId(live.id);
    if (goal == null || !context.mounted) return;
    final result = NodeEventLink.assignEventToGoal(
      calendar,
      nodes,
      event.id,
      goal.id,
      includeSeries: true,
    );
    if (!context.mounted) return;
    if (result.assigned == 0) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(result.error ?? 'Already assigned to “${goal.title}”.'),
        ),
      );
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            result.error != null
                ? 'Assigned ${result.assigned} item(s) to “${goal.title}”; ${result.error}'
                : result.assigned == 1
                ? 'Assigned to “${goal.title}”'
                : 'Assigned ${result.assigned} items to “${goal.title}”',
          ),
          duration: const Duration(seconds: 4),
          persist: false,
          action: SnackBarAction(label: 'Undo', onPressed: undoCubit.undo),
        ),
      );
  }

  void _promptBreakdown(BuildContext context, Node live) {
    final countCtrl = TextEditingController(text: '4');
    final prefixCtrl = TextEditingController(text: 'Step');
    var splitMoney = live.money != null;
    var splitEffort = live.effort != null;
    var spreadDates = true;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Break down “${live.title}”'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Creates ordered step children in one undoable change. '
                  'Dates spread across the goal window; targets split evenly.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: countCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Number of steps (2–30)',
                    border: OutlineInputBorder(),
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: prefixCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Step name prefix',
                    border: OutlineInputBorder(),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Spread due dates'),
                  value: spreadDates,
                  onChanged: (v) => setLocal(() => spreadDates = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Split money target'),
                  value: splitMoney,
                  onChanged: live.money == null
                      ? null
                      : (v) => setLocal(() => splitMoney = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Split time target'),
                  value: splitEffort,
                  onChanged: live.effort == null
                      ? null
                      : (v) => setLocal(() => splitEffort = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final count = int.tryParse(countCtrl.text.trim()) ?? 0;
                if (count < 2 || count > 30) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Enter 2–30 steps')),
                  );
                  return;
                }
                final result = context.read<NodeCubit>().breakdownGoal(
                  live.id,
                  count: count,
                  stepPrefix: prefixCtrl.text.trim().isEmpty
                      ? 'Step'
                      : prefixCtrl.text.trim(),
                  splitMoney: splitMoney,
                  splitEffort: splitEffort,
                  spreadDates: spreadDates,
                );
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      result.error ?? 'Created ${result.ids.length} step(s)',
                    ),
                  ),
                );
              },
              child: const Text('Create steps'),
            ),
          ],
        ),
      ),
    );
  }

  void _promptSubdivide(BuildContext context, Node live) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Subdivide'),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Keep amount',
            prefixText: '\$ ',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final amount = double.tryParse(ctrl.text.trim());
              if (amount != null && amount > 0) {
                context.read<NodeCubit>().subdivideNode(live.id, amount);
                Navigator.pop(ctx);
              }
            },
            child: const Text('Split'),
          ),
        ],
      ),
    );
  }
}

/// Parent goal row in the All view.
///
/// Tapping the row itself opens the goal editor (same as leaf rows);
/// only the chevron expands/collapses the children. The old
/// [ExpansionTile] expanded on any header tap, which left collapsed
/// parents with no discoverable way to edit.
class _ParentTile extends StatefulWidget {
  final EdgeInsetsGeometry tilePadding;
  final Widget leading;
  final Widget title;
  final Widget subtitle;
  final List<Widget> trailingActions;
  final List<Widget> children;
  final bool initiallyExpanded;
  final int expandToken;
  final VoidCallback onTap;

  const _ParentTile({
    super.key,
    required this.tilePadding,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.trailingActions,
    required this.children,
    required this.initiallyExpanded,
    required this.expandToken,
    required this.onTap,
  });

  @override
  State<_ParentTile> createState() => _ParentTileState();
}

class _ParentTileState extends State<_ParentTile> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  void didUpdateWidget(covariant _ParentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expandToken != widget.expandToken) {
      _expanded = widget.initiallyExpanded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          contentPadding: widget.tilePadding,
          leading: widget.leading,
          title: widget.title,
          subtitle: widget.subtitle,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ...widget.trailingActions,
              IconButton(
                tooltip: _expanded ? 'Collapse' : 'Expand',
                icon: AnimatedRotation(
                  turns: _expanded ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.expand_more),
                ),
                onPressed: () => setState(() => _expanded = !_expanded),
              ),
            ],
          ),
          onTap: widget.onTap,
        ),
        if (_expanded) ...widget.children,
      ],
    );
  }
}

class _EmptyNodes extends StatefulWidget {
  const _EmptyNodes();

  @override
  State<_EmptyNodes> createState() => _EmptyNodesState();
}

class _EmptyNodesState extends State<_EmptyNodes> {
  // Cached: the old code created a new Future on every build, re-firing
  // the async check each frame.
  late final Future<bool> _hasLegacy = NodeLegacyMigration.hasLegacy();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _hasLegacy,
      builder: (context, snapshot) {
        final showImport = snapshot.data ?? false;
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.hub_outlined, size: 48),
                const SizedBox(height: 8),
                Text(
                  'No nodes yet',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Build your goal tree here.\n'
                  'Tasks and homework live in Tasks —\n'
                  'add a goal with the + button.',
                  textAlign: TextAlign.center,
                ),
                if (showImport) ...[
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => _import(context),
                    icon: const Icon(Icons.upload_outlined),
                    label: const Text('Import old goals & tasks'),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _import(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Importing…')));
    try {
      final result = await NodeLegacyMigration.importAll(
        context.read<NodeCubit>(),
        context.read<TransactionsCubit>(),
      );
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${result.nodes} node(s), linked ${result.txns} transaction(s)',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }
}
