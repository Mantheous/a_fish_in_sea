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
import 'package:a_fish_in_sea/nodes/view/node_checkbox.dart';
import 'package:a_fish_in_sea/nodes/view/node_editor.dart';
import 'package:a_fish_in_sea/nodes/view/node_finish_sheet.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';

enum _NodeView { all, due, scheduled, money, habits }

class NodesPage extends StatefulWidget {
  const NodesPage({super.key});

  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  _NodeView _view = _NodeView.all;

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
          _ViewRow(
            view: _view,
            onView: (v) => setState(() => _view = v),
          ),
          Expanded(child: _NodeBody(view: _view)),
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
        _NodeView.all => 'All',
        _NodeView.due => 'Due',
        _NodeView.scheduled => 'Scheduled',
        _NodeView.money => 'Money',
        _NodeView.habits => 'Repeating',
      };
}

class _NodeBody extends StatelessWidget {
  final _NodeView view;

  const _NodeBody({required this.view});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NodeCubit, List<Node>>(
      builder: (context, nodes) {
        if (nodes.isEmpty) return const _EmptyNodes();
        final txns = context.watch<TransactionsCubit>().state;
        final txnAmounts = {for (final t in txns) t.id: t.amount};
        final progress = progressForest(
          nodes,
          moneyActualByNodeId: txnAmounts,
        );
        switch (view) {
          case _NodeView.all:
            return _NodeTree(
                nodes: nodes, progress: progress, txnAmounts: txnAmounts);
          case _NodeView.due:
            final queue = priorityQueue(nodes, DateTime.now());
            if (queue.isEmpty) {
              return const Center(child: Text('Nothing due.'));
            }
            return ListView(
              padding: const EdgeInsets.only(bottom: 80),
              children: [
                for (final n in queue)
                  _NodeTile(
                      node: n,
                      nodes: nodes,
                      progress: progress,
                      txnAmounts: txnAmounts,
                      depth: 0,
                      flat: true),
              ],
            );
          case _NodeView.scheduled:
            final items = calendarNodes(nodes);
            if (items.isEmpty) {
              return const Center(child: Text('Nothing scheduled.'));
            }
            return ListView(
              padding: const EdgeInsets.only(bottom: 80),
              children: [
                for (final n in items)
                  _NodeTile(
                      node: n,
                      nodes: nodes,
                      progress: progress,
                      txnAmounts: txnAmounts,
                      depth: 0,
                      flat: true),
              ],
            );
          case _NodeView.money:
            final items = ledgerNodes(nodes)
              ..sort((a, b) => _nodeDate(a).compareTo(_nodeDate(b)));
            if (items.isEmpty) {
              return const Center(child: Text('No money nodes yet.'));
            }
            return ListView(
              padding: const EdgeInsets.only(bottom: 80),
              children: [
                for (final n in items)
                  _NodeTile(
                      node: n,
                      nodes: nodes,
                      progress: progress,
                      txnAmounts: txnAmounts,
                      depth: 0,
                      flat: true),
              ],
            );
          case _NodeView.habits:
            final items = nodes.where((n) => n.isTemplate).toList();
            if (items.isEmpty) {
              return const Center(
                  child: Text(
                      'No repeating templates yet.\nEnable Repeats in the editor.'));
            }
            return ListView(
              padding: const EdgeInsets.only(bottom: 80),
              children: [
                for (final n in items)
                  _NodeTile(
                      node: n,
                      nodes: nodes,
                      progress: progress,
                      txnAmounts: txnAmounts,
                      depth: 0,
                      flat: false),
              ],
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

  const _NodeTree({
    required this.nodes,
    required this.progress,
    required this.txnAmounts,
  });

  @override
  Widget build(BuildContext context) {
    final roots = nodes.where((n) => n.parentIds.isEmpty).toList()
      ..sort(_compareRoots);
    if (roots.isEmpty) {
      // DAG cycle fallback (shouldn't happen): show everything flat.
      return ListView(
        padding: const EdgeInsets.only(bottom: 80),
        children: [
          for (final n in nodes)
            _NodeTile(
                node: n,
                nodes: nodes,
                progress: progress,
                txnAmounts: txnAmounts,
                depth: 0,
                flat: true),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 80),
      children: [
        for (final n in roots)
          _NodeTile(
              node: n,
              nodes: nodes,
              progress: progress,
              txnAmounts: txnAmounts,
              depth: 0,
              flat: false,
              visited: {n.id}),
      ],
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

  const _NodeTile({
    required this.node,
    required this.nodes,
    required this.progress,
    required this.txnAmounts,
    required this.depth,
    required this.flat,
    this.visited = const {},
  });

  @override
  Widget build(BuildContext context) {
    final live =
        context.watch<NodeCubit>().byId(node.id) ?? node;
    final kids = flat
        ? const <Node>[]
        : _children(live)
          ..sort((a, b) => _compareKids(a, b));
    final value = progress[live.id] ?? 0;
    final theme = Theme.of(context);
    final subtitle = _subtitle(context, live, value);
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
        children: [
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
          PopupMenuButton<String>(
            onSelected: (choice) =>
                _onMenu(context, live, choice),
            itemBuilder: (context) => [
              const PopupMenuItem(
                  value: 'edit', child: Text('Edit')),
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
        ],
      ),
      onTap: () => showNodeEditor(context, existing: live),
    );
    if (kids.isEmpty) return tile;
    return ExpansionTile(
      tilePadding:
          EdgeInsets.only(left: 16 + depth * 20, right: 8),
      leading: _leading(context, live),
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
              visited: {...visited, k.id}),
      ],
    );
  }

  List<Node> _children(Node parent) {
    final byId = {for (final n in nodes) n.id: n};
    final out = <Node>[];
    for (final n in nodes) {
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

  String _subtitle(BuildContext context, Node live, double value) {
    final parts = <String>[];
    if (live.money != null) {
      final m = live.money!;
      final actual = moneyActualForNode(live, nodes,
          txnAmountsById: txnAmounts);
      parts.add(
          '\$${actual.toStringAsFixed(2)} / \$${m.effectiveTarget.toStringAsFixed(2)}');
    } else if (live.effort != null) {
      final actual = timeActualForNode(live, nodes);
      parts.add(
          '${actual.toStringAsFixed(0)}m / ${live.effort!.targetMinutes}m');
    }
    if (live.rule != null &&
        live.rule!.kind == NodeRuleKind.homeworkAhead) {
      final r = evaluateHomeworkAhead(
          all: nodes,
          now: DateTime.now(),
          horizonDays: live.rule!.horizonDays);
      parts.add(r.satisfied
          ? 'ahead ✓ (${r.dueSoon.length} due soon)'
          : '${r.doneCount}/${r.dueSoon.length} ready');
    }
    final due = live.schedule?.due;
    if (due != null) {
      final label = live.isOverdueAt(DateTime.now())
          ? 'overdue'
          : 'due ${DateFormat('EEE, MMM d').format(due)}';
      parts.add(label);
    } else if (live.hasCalendarBlock) {
      parts.add(
          'scheduled ${DateFormat('EEE, MMM d').format(live.schedule!.start!)}');
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
      case 'edit':
        showNodeEditor(context, existing: live);
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
        final spent = moneyActualForNode(live, nodes,
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Node deleted'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () => context.read<UndoCubit>().undo(),
            ),
          ),
        );
    }
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

class _EmptyNodes extends StatelessWidget {
  const _EmptyNodes();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: NodeLegacyMigration.hasLegacy(),
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
                  'Goals, tasks, budgets and expenses live here now.\n'
                  'Add one with the + button.',
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
