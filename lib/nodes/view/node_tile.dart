import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../common/undo/undo_cubit.dart';
import '../../finances/bloc/transactions_cubit.dart';
import '../../finances/service/node_transaction_cleanup.dart';
import '../../navigation/bloc/navigation_cubit.dart';
import '../../planner/bloc/calendar_cubit.dart';
import '../../planner/bloc/feed_cubit.dart';
import '../../planner/model/feed.dart';
import '../../planner/model/planner_event.dart';
import '../../planner/service/feed_links.dart';
import '../../planner/view/event_colors.dart';
import '../../planner/view/task_highlight_tint.dart';
import '../../planner/view/task_tile_helpers.dart';
import '../bloc/node_cubit.dart';
import '../model/node.dart';
import '../service/node_calendar.dart';
import '../service/node_event_link.dart';
import 'goal_picker.dart';
import 'node_checkbox.dart';
import 'node_editor.dart';
import 'node_finish_sheet.dart';
import 'schedule_sheet.dart';
import 'timer_edit_sheet.dart';

/// One task row: checkbox, title, class/due/work lines, and the
/// play/schedule/more controls. Shared by the Tasks page and the calendar
/// side panel so both surfaces stay identical.
class NodeTile extends StatelessWidget {
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

  /// Upcoming (future, timed) calendar entries per node id, hoisted by the
  /// parent list. Drives the schedule button's tint + count badge. Null in
  /// standalone embeds: the tile then derives its own count from
  /// [CalendarCubit] via [futureCalendarEntryCounts].
  final Map<String, int>? upcomingEventCounts;

  /// Earliest upcoming planned slot per node id, from the same pass as
  /// [upcomingEventCounts]. Names the day on the "Planned …" line so a plan
  /// visibly lands before its due date. Null in standalone embeds: the tile
  /// then derives the slot for this node only.
  final Map<String, PlannedSlot>? plannedSlots;
  // Multi-select state. While [selecting], the leading checkbox becomes
  // a selection box and taps toggle selection instead of opening the
  // editor; long-press is what enters selection mode.
  final bool selected;
  final bool selecting;
  final VoidCallback? onToggleSelection;
  final VoidCallback? onEnterSelection;

  /// Overrides what a normal (non-selecting) tap does. Defaults to opening
  /// the node editor; the calendar side panel selects the task's calendar
  /// event instead so the node menu stays available from the ⋮ menu.
  final VoidCallback? onTap;

  const NodeTile({
    super.key,
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
    this.upcomingEventCounts,
    this.plannedSlots,
    this.selected = false,
    this.selecting = false,
    this.onToggleSelection,
    this.onEnterSelection,
    this.onTap,
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
    Feed? resolvedFeed;
    // The class node is the current identity; classLabel is only the
    // denormalized snapshot (and may keep legacy feed provenance).
    var classLabel = live.classLabel;
    if (live.classNodeId != null) {
      Node? cls = nodeById?[live.classNodeId];
      if (cls == null) {
        try {
          cls = context.read<NodeCubit>().byId(live.classNodeId!);
        } catch (_) {}
      }
      if (cls != null) classLabel = cls.title;
    }
    if (showClass && classLabel != null) {
      final colorPrefs = colorPrefsOf(context);
      chipColor = resolveClassColor(
        classLabel,
        colorPrefs,
        useOverrides: colorPrefs.applyToTaskLists,
      );
      chipLabel = classLabel;
    } else {
      Feed? feed;
      if (showClass && live.classId != null) {
        final map = feedById;
        feed = map != null
            ? map[live.classId]
            : context.read<FeedCubit>().byId(live.classId!);
      }
      resolvedFeed = feed;
      chipColor = feed == null
          ? Theme.of(context).colorScheme.primary
          : mutedCalendarColor(feed.color);
      chipLabel = feed?.name ?? '';
    }
    // Homework link-out needs the feed even when the class chip is hidden
    // (Tasks > Homework passes showClass false) or when the chip uses
    // classLabel instead of the feed.
    if (resolvedFeed == null && live.isHomework && live.classId != null) {
      final map = feedById;
      if (map != null) {
        resolvedFeed = map[live.classId];
      } else {
        try {
          resolvedFeed = context.read<FeedCubit>().byId(live.classId!);
        } catch (_) {}
      }
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
    // Upcoming timed entries: future, non-all-day calendar blocks linked to
    // this task. Drives the schedule button's tint and count badge; unlike
    // [hasEvent] it ignores all-day deadlines and past occurrences.
    final upcomingCount = upcomingEventCounts != null
        ? (upcomingEventCounts![live.id] ?? 0)
        : _countUpcomingEvents(context, live, effectiveNow);
    // The plan the calendar shows for this node: its next upcoming slot
    // (own block or linked event). Its own block stays visible below even
    // when it already started or passed, so a missed plan doesn't vanish.
    final nextPlan = plannedSlots != null
        ? plannedSlots![live.id]
        : _nextPlannedSlot(context, live, effectiveNow);
    final workLine = taskWorkLine(
      context,
      live,
      now: effectiveNow,
      plan: nextPlan,
      indexById: indexById,
      indexByParent: indexByParent,
    );
    final due = live.schedule?.due;
    // Due today outranks the custom tint: same highlight, hotter color.
    // (A highlighted row is always open — the highlight set is open-only
    // — so no extra status check is needed.)
    final isDueTodayHighlight =
        highlightMatched && due != null && isDueToday(due, effectiveNow);
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
                  'Due ${formatTaskDue(due)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: live.isOverdueAt(effectiveNow)
                        ? theme.colorScheme.error
                        : isDueTodayHighlight
                        ? dueTodayColor(theme)
                        : highlightMatched
                        ? highlightTextColor
                        : null,
                    fontWeight:
                        isDueToday(due, effectiveNow) || highlightMatched
                        ? FontWeight.bold
                        : null,
                  ),
                ),
            ],
          ),
          // Running timers can correct a late start here. Finished
          // recordings are adjusted from the Calendar's report chips.
          if (workLine != null)
            live.isTracking
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
              child: AssigneeLine(assignees: live.assignees),
            ),
          // Homework details surfaced from the feed: iCal DESCRIPTION
          // arrives via imports as notes (any LMS), clamped so long bodies
          // don't overwhelm the row. Learning Suite ships only the feed
          // link, so homework without notes gets a link-out instead.
          if ((live.notes ?? '').trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                live.notes!.trim(),
                style: theme.textTheme.bodySmall,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            )
          else if (live.isHomework &&
              resolvedFeed?.kind == FeedKind.learningSuite)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Open in Learning Suite'),
                onPressed: () async {
                  // The feed URL is the iCal export, not a page: opening it
                  // downloads a .ics file. Jump to Learning Suite instead.
                  final uri = learningSuiteHomeUri();
                  try {
                    if (kIsWeb) {
                      await launchUrl(uri, webOnlyWindowName: '_blank');
                    } else {
                      await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      );
                    }
                  } catch (_) {}
                },
              ),
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
          Badge(
            isLabelVisible: upcomingCount > 1,
            label: Text('$upcomingCount'),
            child: IconButton(
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
                color: upcomingCount > 0 ? theme.colorScheme.primary : null,
              ),
              onPressed: () => showScheduleSheet(context, nodeId: live.id),
            ),
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
              if (value == 'show-in-goals') _showInGoals(context, live);
              if (value == 'assign-goal') _assignToGoal(context, live);
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'schedule', child: Text('Schedule…')),
              PopupMenuItem(
                value: 'assign-goal',
                child: Text('Assign to goal…'),
              ),
              PopupMenuItem(
                value: 'show-in-goals',
                child: Text('Show in goals'),
              ),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
      onTap: selecting
          ? onToggleSelection
          : (onTap ?? () => showNodeEditor(context, existing: live)),
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

  /// Per-tile fallback for embeds that didn't hoist [upcomingEventCounts]
  /// (standalone widget tests): single node through the shared counter.
  static int _countUpcomingEvents(
    BuildContext context,
    Node node,
    DateTime now,
  ) {
    try {
      final events = context.read<CalendarCubit>().state;
      return futureCalendarEntryCounts([node], events, now)[node.id] ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Per-tile fallback for embeds that didn't hoist [plannedSlots]: the next
  /// planned slot for this one node, through the shared planner rules.
  static PlannedSlot? _nextPlannedSlot(
    BuildContext context,
    Node node,
    DateTime now,
  ) {
    try {
      final events = context.read<CalendarCubit>().state;
      return upcomingNodePlans([node], events, now).nextSlots[node.id];
    } catch (_) {
      return null;
    }
  }

  /// Attaches this row under a goal without opening the full editor. The
  /// picker hides the node itself and its descendants, and
  /// [NodeEventLink.assignNodeToGoal] reports cycle/instance errors.
  Future<void> _assignToGoal(BuildContext context, Node node) async {
    final picked = await showGoalPicker(
      context,
      excludeNodeId: node.id,
      title: 'Assign to goal',
    );
    if (picked == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    String? error;
    try {
      error = NodeEventLink.assignNodeToGoal(
        context.read<NodeCubit>(),
        node.id,
        picked.id,
      );
    } catch (_) {
      error = 'Could not assign to that goal.';
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(error ?? 'Assigned to “${picked.title}”'),
          duration: const Duration(seconds: 3),
          persist: false,
        ),
      );
  }

  /// Jumps to the goal tree with this task revealed: the Nodes page opens
  /// on the All tree view with the ancestor chain expanded and this task
  /// highlighted. Tolerates a missing [NavigationCubit] so standalone
  /// widget tests pumping the tile without the app shell keep working.
  void _showInGoals(BuildContext context, Node node) {
    try {
      context.read<NavigationCubit>().showNodeInGoals(node.id);
    } catch (_) {}
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
          action: SnackBarAction(label: 'Undo', onPressed: undoCubit.undo),
        ),
      );
  }
}
