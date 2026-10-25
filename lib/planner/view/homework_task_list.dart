import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../common/undo/undo_cubit.dart';
import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/model/node.dart';
import '../../nodes/view/class_picker.dart';
import '../../nodes/service/node_calendar.dart';
import '../../nodes/service/node_progress.dart';
import '../../nodes/view/node_tile.dart';
import '../bloc/assignment_rules_cubit.dart';
import '../bloc/calendar_cubit.dart';
import '../bloc/feed_cubit.dart';
import '../bloc/settings_cubit.dart';
import '../model/assignment_template.dart';
import '../model/feed.dart';
import 'assignment_rules_sheet.dart';
import 'event_colors.dart';
import 'feed_manager.dart';
import 'task_list_parts.dart';
import 'tasks_view_filtering.dart';

/// The Tasks page's Homework tab: assignments grouped by class with an
/// expandable card each. Shared with the calendar side panel.
class HomeworkTaskList extends StatefulWidget {
  final Set<String> selected;
  final bool selecting;
  final void Function(String id) onToggleSelection;
  final void Function(String id) onEnterSelection;
  final void Function(Iterable<String> ids) onSelectAll;
  final void Function(Iterable<String> ids) onDeselectAll;

  /// Overrides what a normal tap does (default: open the node editor).
  final ValueChanged<Node>? onTaskTap;

  const HomeworkTaskList({
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
  State<HomeworkTaskList> createState() => _HomeworkTaskListState();
}

class _HomeworkTaskListState extends State<HomeworkTaskList>
    with AutomaticKeepAliveClientMixin {
  /// Class groups the user collapsed. New groups default to expanded.
  final Set<String> _collapsed = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        final feeds = context.read<FeedCubit>().state;
        context.read<NodeCubit>().ensureHomeworkStructure(
          feedNames: {for (final feed in feeds) feed.id: feed.name},
        );
      } catch (_) {}
    });
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final nodeCubit = context.watch<NodeCubit>();
    final feedCubit = context.watch<FeedCubit>();
    final colorPrefs = colorPrefsOf(context);
    final viewOptions = viewOptionsOf(context);
    final now = DateTime.now();
    final firstDayOfWeek = _firstDayOfWeekOf(context);
    // One calendar pass per build: the counts drive the schedule tint and,
    // through their key set, the Planned/Unplanned filter — so a tinted
    // clock always reads as planned.
    final allNodes = nodeCubit.state;
    final calendarState = context.watch<CalendarCubit>().state;
    final upcomingCounts =
        futureCalendarEntryCounts(allNodes, calendarState, now);
    final plannedIds = upcomingCounts.keys.toSet();
    final tints =
        taskTintMap(allNodes, viewOptions, now,
            plannedNodeIds: plannedIds, firstDayOfWeek: firstDayOfWeek);
    var imported = applyTaskViewOptions(
      feedCubit.visibleNodes(
        nodeCubit.state.where((n) => n.isHomework).toList(),
      ),
      viewOptions,
      now,
      plannedNodeIds: plannedIds,
      firstDayOfWeek: firstDayOfWeek,
    );
    if (imported.isEmpty) {
      if (viewOptions.isFiltering) {
        return FilteredTaskEmpty(filterName: viewOptions.activeFilter.name);
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
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => showClassPicker(context, createOnly: true),
                icon: const Icon(Icons.school_outlined),
                label: const Text('Create a class without a feed'),
              ),
            ],
          ),
        ),
      );
    }
    final classNodeTitles = {
      for (final node in allNodes)
        if (node.isClassNode) node.id: node.title,
    };
    final byClass = <String, List<Node>>{};
    for (final node in imported) {
      // A class-node membership unifies imported and manual work in one
      // group even when their feed labels differ (Learning Suite vs a
      // hand-created class).
      final key =
          node.classNodeId ?? node.classLabel ?? node.classId ?? '';
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
    final nodeById = {for (final n in allNodes) n.id: n};
    final indexes = buildNodeIndexes(allNodes);
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
      final classTitle = classNodeTitles[key];
      final labeled = !list.every((node) => node.classLabel == null);
      if (classTitle != null) {
        groupMeta[key] = (
          color: resolveClassColor(
            classTitle,
            colorPrefs,
            useOverrides: colorPrefs.applyToTaskLists,
          ),
          name: classTitle,
          removable: false,
        );
      } else if (labeled) {
        groupMeta[key] = (
          color: resolveClassColor(
            key,
            colorPrefs,
            useOverrides: colorPrefs.applyToTaskLists,
          ),
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
                      IconButton(
                        tooltip: 'New class',
                        icon: const Icon(Icons.create_new_folder_outlined),
                        onPressed: () => showClassPicker(context, createOnly: true),
                      ),
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
              return SelectAllRow(
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
                      NodeTile(
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
                        upcomingEventCounts: upcomingCounts,
                        selected: widget.selected.contains(node.id),
                        selecting: widget.selecting,
                        onToggleSelection: () =>
                            widget.onToggleSelection(node.id),
                        onEnterSelection: () =>
                            widget.onEnterSelection(node.id),
                        onTap: widget.onTaskTap == null
                            ? null
                            : () => widget.onTaskTap!(node),
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

int _firstDayOfWeekOf(BuildContext context) {
  try {
    return context.read<SettingsCubit>().state.firstDayOfWeek;
  } catch (_) {
    return 1;
  }
}

