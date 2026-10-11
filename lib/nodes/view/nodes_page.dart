import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import 'package:a_fish_in_sea/common/undo/undo_bar.dart';
import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/navigation/view/app_drawer.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_legacy_migration.dart';
import 'package:a_fish_in_sea/nodes/service/node_progress.dart';
import 'package:a_fish_in_sea/nodes/service/node_tree_ops.dart';
import 'package:a_fish_in_sea/nodes/view/node_checkbox.dart';
import 'package:a_fish_in_sea/nodes/view/node_editor.dart';
import 'package:a_fish_in_sea/nodes/view/node_finish_sheet.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';

enum _NodeView { leaves, all, due, scheduled, money, habits }

final _nodesDateFormat = DateFormat('EEE, MMM d');

class NodesPage extends StatefulWidget {
  const NodesPage({super.key});

  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  _NodeView _view = _NodeView.leaves;
  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _expandAll = false;
  int _expandToken = 0;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nodes'),
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
            padding:
                const EdgeInsets.fromLTRB(12, 8, 12, 0),
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
                    onChanged: (v) =>
                        setState(() => _query = v),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: _expandAll
                      ? 'Collapse all'
                      : 'Expand all',
                  child: IconButton(
                    icon: Icon(_expandAll
                        ? Icons.unfold_less
                        : Icons.unfold_more),
                    onPressed: () => setState(() {
                      _expandAll = !_expandAll;
                      _expandToken++;
                    }),
                  ),
                ),
              ],
            ),
          ),
          _ViewRow(
            view: _view,
            onView: (v) => setState(() => _view = v),
          ),
          Expanded(
              child: _NodeBody(
            view: _view,
            query: _query,
            expandAll: _expandAll,
            expandToken: _expandToken,
          )),
        ],
      ),
    );
  }
}

class _ViewRow extends StatelessWidget {
  final _NodeView view;
  final ValueChanged<_NodeView> onView;

  const _ViewRow({required this.view, required this.onView});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          for (final v in _NodeView.values)
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

  static String _label(_NodeView v) => switch (v) {
        _NodeView.leaves => 'Leaves',
        _NodeView.all => 'All',
        _NodeView.due => 'Due',
        _NodeView.scheduled => 'Scheduled',
        _NodeView.money => 'Money',
        _NodeView.habits => 'Repeating',
      };
}

class _NodeBody extends StatelessWidget {
  final _NodeView view;
  final String query;
  final bool expandAll;
  final int expandToken;

  const _NodeBody(
      {required this.view,
      this.query = '',
      this.expandAll = false,
      this.expandToken = 0});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NodeCubit, List<Node>>(
      builder: (context, nodes) {
        // Goal tree only: homework imports and calendar links live in
        // Tasks/Calendar, never auto-fill this page.
        final goals = goalNodes(nodes);
        if (goals.isEmpty) return const _EmptyNodes();
        final txns = context.watch<TransactionsCubit>().state;
        final txnAmounts = {for (final t in txns) t.id: t.amount};
        final progress = progressForest(
          goals,
          moneyActualByNodeId: txnAmounts,
        );
        final trimmed = query.trim();
        final visible = trimmed.isEmpty
            ? null
            : filterTreeIds(nodes, trimmed);
        List<Node> matching(List<Node> items) => visible == null
            ? items
            : items.where((n) => visible.contains(n.id)).toList();
        // Hoisted once per body build (not per tile): shared DAG indexes,
        // liveness map, one `now`, and one homework-ahead evaluation
        // (the old code re-ran it O(n) per rule tile).
        final indexes = buildNodeIndexes(goals);
        final nodeById = indexes.byId;
        final byParent = indexes.byParent;
        final now = DateTime.now();
        HomeworkAheadResult? homeworkAhead;
        HomeworkAheadResult getHomeworkAhead() =>
            homeworkAhead ??= evaluateHomeworkAhead(
              all: nodes,
              now: now,
              horizonDays: 3,
            );
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
          case _NodeView.leaves:
            final items = matching(leafNodes(nodes));
            if (items.isEmpty) {
              return const Center(child: Text('No leaf nodes.'));
            }
            return flatList(items);
          case _NodeView.all:
            return _NodeTree(
              nodes: goals,
              progress: progress,
              txnAmounts: txnAmounts,
              visible: visible,
              expandAll: expandAll,
              expandToken: expandToken,
              nodeById: nodeById,
              byParent: byParent,
              now: now,
              homeworkAhead: getHomeworkAhead(),
            );
          case _NodeView.due:
            final queue = matching(priorityQueue(goals, now));
            if (queue.isEmpty) {
              return const Center(child: Text('Nothing due.'));
            }
            return flatList(queue);
          case _NodeView.scheduled:
            final items = matching(calendarNodes(goals));
            if (items.isEmpty) {
              return const Center(child: Text('Nothing scheduled.'));
            }
            return flatList(items);
          case _NodeView.money:
            final items = matching(ledgerNodes(goals))
              ..sort((a, b) => _nodeDate(a).compareTo(_nodeDate(b)));
            if (items.isEmpty) {
              return const Center(child: Text('No money nodes yet.'));
            }
            return flatList(items);
          case _NodeView.habits:
            final items = matching(
                goals.where((n) => n.isTemplate).toList());
            if (items.isEmpty) {
              return const Center(
                  child: Text(
                      'No repeating templates yet.\nEnable Repeats in the editor.'));
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
  final Map<String, Node>? nodeById;
  final Map<String, List<Node>>? byParent;
  final DateTime? now;
  final HomeworkAheadResult? homeworkAhead;
  final Set<String>? visible;
  final bool expandAll;
  final int expandToken;

  const _NodeTree({
    required this.nodes,
    required this.progress,
    required this.txnAmounts,
    this.nodeById,
    this.byParent,
    this.now,
    this.homeworkAhead,
    this.visible,
    this.expandAll = false,
    this.expandToken = 0,
  });

  @override
  Widget build(BuildContext context) {
    final inView = visible == null
        ? nodes
        : nodes.where((n) => visible!.contains(n.id)).toList();
    if (inView.isEmpty) {
      return const Center(
          child: Text('No goals match the search.'));
    }
    final visibleIds =
        visible ?? {for (final n in nodes) n.id};
    // Filtered roots: visible nodes with no visible parent.
    final roots = inView
        .where((n) => n.parentIds
            .where(visibleIds.contains)
            .isEmpty)
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
            depth: 0,
            flat: true,
            visible: visible,
            expandAll: expandAll,
            expandToken: expandToken,
            nodeById: nodeById,
            byParent: byParent,
            now: now,
            homeworkAhead: homeworkAhead,
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

  const _NodeTile({
    required this.node,
    required this.nodes,
    required this.progress,
    required this.txnAmounts,
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
    final value = progress[live.id] ?? 0;
    final theme = Theme.of(context);
    final subtitle = _subtitle(context, live, value, kids.length);
    final tile = ListTile(
      contentPadding:
          EdgeInsets.only(left: 16 + depth * 20, right: 8),
      leading: _leading(context, live),
      title: Text(
        live.title,
        style: TextStyle(
          decoration: live.isDone ||
                  live.status == NodeStatus.failed
              ? TextDecoration.lineThrough
              : null,
          color: live.status == NodeStatus.failed
              ? theme.colorScheme.error
              : live.isDone
                  ? theme.colorScheme.outline
                  : null,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(subtitle, style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: value),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: _trailingActions(context, live, theme),
      ),
      onTap: () => showNodeEditor(context, existing: live),
    );
    if (kids.isEmpty) return tile;
    return ExpansionTile(
      key: ValueKey('${live.id}:$expandToken:$expandAll'),
      initiallyExpanded: expandAll,
      tilePadding:
          EdgeInsets.only(left: 16 + depth * 20, right: 8),
      leading: _leading(context, live),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ..._trailingActions(context, live, theme),
          const _ExpandChevron(),
        ],
      ),
      title: Text(live.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(subtitle, style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: value),
        ],
      ),
      children: [
        for (final k in kids)
          _NodeTile(
            node: k,
            nodes: nodes,
            progress: progress,
            txnAmounts: txnAmounts,
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
          ),
      ],
    );
  }

  /// Action buttons shared by leaf rows ([ListTile]) and parent rows
  /// ([ExpansionTile]): record start/stop, Add subgoal, and the overflow
  /// menu. Parent rows previously had no trailing at all, which hid the
  /// Add subgoal button (and the rest) on every goal with children.
  List<Widget> _trailingActions(
      BuildContext context, Node live, ThemeData theme) {
    return [
      if (live.isTracking)
        IconButton(
          tooltip: 'Stop recording',
          icon: Icon(Icons.stop,
              color: theme.colorScheme.primary),
          onPressed: () => stopNodeAndFinish(context, live.id),
        )
      else if (live.isOpen)
        IconButton(
          tooltip: 'Start recording',
          icon: const Icon(Icons.play_arrow),
          onPressed: () {
            try {
              context.read<NodeCubit>().startTracking(live.id);
            } catch (_) {}
          },
        ),
      IconButton(
        tooltip: 'Add subgoal',
        icon: const Icon(Icons.add_task_outlined),
        onPressed: () => _onMenu(context, live, 'subgoal'),
      ),
      PopupMenuButton<String>(
        onSelected: (choice) =>
            _onMenu(context, live, choice),
        itemBuilder: (context) => [
          const PopupMenuItem(
              value: 'subgoal', child: Text('Add subgoal')),
          const PopupMenuItem(
              value: 'edit', child: Text('Edit')),
          const PopupMenuItem(
              value: 'add-child', child: Text('Add child step')),
          const PopupMenuItem(
              value: 'breakdown',
              child: Text('Auto-breakdown into steps…')),
          const PopupMenuItem(
              value: 'duplicate',
              child: Text('Duplicate subtree')),
          const PopupMenuItem(
              value: 'toggle', child: Text('Toggle done')),
          PopupMenuItem(
              value: 'fail',
              child: Text(live.status == NodeStatus.failed
                  ? 'Unmark failed'
                  : 'Mark failed')),
          if (live.isTemplate)
            const PopupMenuItem(
                value: 'generate',
                child: Text('Generate schedule')),
          if (live.money != null) ...[
            const PopupMenuItem(
                value: 'subdivide', child: Text('Subdivide')),
            if (live.money!.isRecurring)
              const PopupMenuItem(
                  value: 'rollover',
                  child: Text('Rollover period')),
          ],
          const PopupMenuItem(
              value: 'delete', child: Text('Delete')),
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

  Widget _leading(BuildContext context, Node live) {
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
    return NodeCheckbox(node: live);
  }

  String _subtitle(BuildContext context, Node live, double value,
      int childCount) {
    final effectiveNow = now ?? DateTime.now();
    final parts = <String>[];
    if (childCount > 0) {
      parts.add('$childCount step${childCount == 1 ? '' : 's'}');
    }
    if (live.money != null) {
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
          '\$${actual.toStringAsFixed(2)} / \$${m.effectiveTarget.toStringAsFixed(2)}');
    } else if (live.effort != null) {
      final actual = byParent != null && nodeById != null
          ? timeActualForNodeIndexed(
              live, byId: nodeById!, byParent: byParent!)
          : timeActualForNode(live, nodes);
      parts.add(
          '${actual.toStringAsFixed(0)}m / ${live.effort!.targetMinutes}m');
    }
    if (live.rule != null &&
        live.rule!.kind == NodeRuleKind.homeworkAhead) {
      final r = homeworkAhead ??
          evaluateHomeworkAhead(
            all: context.read<NodeCubit>().state,
            now: effectiveNow,
            horizonDays: live.rule!.horizonDays,
          );
      parts.add(r.satisfied
          ? 'ahead ✓ (${r.dueSoon.length} due soon)'
          : '${r.doneCount}/${r.dueSoon.length} ready');
    }
    final due = live.schedule?.due;
    if (due != null) {
      final label = live.isOverdueAt(effectiveNow)
          ? 'overdue'
          : 'due ${_nodesDateFormat.format(due)}';
      parts.add(label);
    } else if (live.hasCalendarBlock) {
      parts.add(
          'scheduled ${_nodesDateFormat.format(live.schedule!.start!)}');
    }
    if (live.isInstance) parts.add('instance');
    if ((live.schedule?.isFixed ?? false) ||
        (live.money?.isFixed ?? false)) {
      parts.add('fixed');
    }
    parts.add('${(value * 100).round()}%');
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
          SnackBar(
              content: Text(error ?? 'Duplicated “${live.title}”')),
        );
      case 'toggle':
        cubit.toggleDone(live.id);
      case 'fail':
        cubit.setStatus(
            live.id,
            live.status == NodeStatus.failed
                ? NodeStatus.open
                : NodeStatus.failed);
      case 'generate':
        final made = cubit.generateInstances(
          templateId: live.id,
          from: DateTime.now(),
          horizon: DateTime.now().add(const Duration(days: 365)),
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Generated $made instance(s)')),
        );
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
            : moneyActualForNode(live, nodes,
                txnAmountsById: txnAmounts);
        cubit.applyRollover(live.id, spent);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rolled over to next period')),
        );
      case 'delete':
        final eventId =
            live.calendarEventId ?? live.sourceEventId;
        cubit.deleteNode(live.id);
        if (eventId != null) {
          try {
            context.read<CalendarCubit>().clearTaskLink(eventId);
          } catch (_) {}
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
                onPressed: () => context.read<UndoCubit>().undo(),
              ),
            ),
          );
    }
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
                final count =
                    int.tryParse(countCtrl.text.trim()) ?? 0;
                if (count < 2 || count > 30) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Enter 2–30 steps')),
                  );
                  return;
                }
                final result =
                    context.read<NodeCubit>().breakdownGoal(
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
                      content: Text(result.error ??
                          'Created ${result.ids.length} step(s)')),
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
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
              labelText: 'Keep amount', prefixText: '\$ '),
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
                context
                    .read<NodeCubit>()
                    .subdivideNode(live.id, amount);
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

/// Expand/collapse chevron for parent goal rows.
///
/// Parent rows use [ExpansionTile] with custom trailing actions, which
/// replaces the tile's default expand icon — so the chevron is rebuilt
/// here, driven by the tile's own [ExpansibleController].
class _ExpandChevron extends StatelessWidget {
  const _ExpandChevron();

  @override
  Widget build(BuildContext context) {
    final controller = ExpansibleController.maybeOf(context);
    if (controller == null) return const Icon(Icons.expand_more);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => AnimatedRotation(
        turns: controller.isExpanded ? 0.5 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: const Icon(Icons.expand_more),
      ),
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
                Text('No nodes yet',
                    style: Theme.of(context).textTheme.titleMedium),
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
    messenger.showSnackBar(
      const SnackBar(content: Text('Importing…')),
    );
    try {
      final result = await NodeLegacyMigration.importAll(
        context.read<NodeCubit>(),
        context.read<TransactionsCubit>(),
      );
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
            content: Text(
                'Imported ${result.nodes} node(s), linked ${result.txns} transaction(s)')),
      );
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    }
  }
}
