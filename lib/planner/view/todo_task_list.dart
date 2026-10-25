import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/model/node.dart';
import '../../nodes/service/node_calendar.dart';
import '../../nodes/service/node_progress.dart';
import '../../nodes/view/node_tile.dart';
import '../bloc/calendar_cubit.dart';
import '../bloc/feed_cubit.dart';
import '../bloc/settings_cubit.dart';
import 'task_list_parts.dart';
import 'tasks_view_filtering.dart';

/// The Tasks page's To-Do list: open nodes, filtered by the active view
/// options, each row a [NodeTile]. Shared with the calendar side panel.
class TodoTaskList extends StatelessWidget {
  final Set<String> selected;
  final bool selecting;
  final void Function(String id) onToggleSelection;
  final void Function(String id) onEnterSelection;
  final void Function(Iterable<String> ids) onSelectAll;
  final void Function(Iterable<String> ids) onDeselectAll;

  /// Overrides what a normal tap does (default: open the node editor).
  final ValueChanged<Node>? onTaskTap;

  const TodoTaskList({
    super.key,
    required this.selected,
    required this.selecting,
    required this.onToggleSelection,
    required this.onEnterSelection,
    required this.onSelectAll,
    required this.onDeselectAll,
    this.onTaskTap,
  });

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NodeCubit, List<Node>>(
      builder: (context, nodes) {
        final feedCubit = context.watch<FeedCubit>();
        final nodeCubit = context.read<NodeCubit>();
        final viewOptions = viewOptionsOf(context);
        final now = DateTime.now();
        final firstDayOfWeek = _firstDayOfWeekOf(context);
        // One calendar pass per build: the counts drive the schedule tint
        // and, through their key set, the Planned/Unplanned filter — so a
        // tinted clock always reads as planned — and the same pass hands
        // each tile the slot its "Planned …" line names.
        final calendarState = context.watch<CalendarCubit>().state;
        final plans = upcomingNodePlans(nodes, calendarState, now);
        final upcomingCounts = plans.counts;
        final plannedIds = upcomingCounts.keys.toSet();
        final tints = taskTintMap(nodeCubit.state, viewOptions, now,
            plannedNodeIds: plannedIds,
            firstDayOfWeek: firstDayOfWeek);
        var open = applyTaskViewOptions(
          feedCubit.visibleNodes(nodeCubit.openNodes),
          viewOptions,
          now,
          plannedNodeIds: plannedIds,
          firstDayOfWeek: firstDayOfWeek,
        );
        if (open.isEmpty) {
          return viewOptions.isFiltering
              ? FilteredTaskEmpty(filterName: viewOptions.activeFilter.name)
              : const EmptyTodoList();
        }
        // Precompute once per list build (not per tile): calendar link set,
        // feed map, node indexes, and a single `now`. Tiles receive plain
        // data and use `read` — no per-tile full-state watches.
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
            return NodeTile(
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
              upcomingEventCounts: upcomingCounts,
              plannedSlots: plans.nextSlots,
              selected: selected.contains(node.id),
              selecting: selecting,
              onToggleSelection: () => onToggleSelection(node.id),
              onEnterSelection: () => onEnterSelection(node.id),
              onTap: onTaskTap == null ? null : () => onTaskTap!(node),
            );
          },
        );
        if (!selecting) return list;
        final allIds = [for (final n in open) n.id];
        final allSelected = allIds.every(selected.contains);
        final count = allIds.where(selected.contains).length;
        return Column(
          children: [
            SelectAllRow(
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

int _firstDayOfWeekOf(BuildContext context) {
  try {
    return context.read<SettingsCubit>().state.firstDayOfWeek;
  } catch (_) {
    return 1;
  }
}

