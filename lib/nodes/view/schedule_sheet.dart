import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../navigation/bloc/navigation_cubit.dart';
import '../../planner/bloc/assignment_estimates_cubit.dart';
import '../../planner/bloc/assignment_rules_cubit.dart';
import '../../planner/bloc/calendar_draft_cubit.dart';
import '../../planner/bloc/settings_cubit.dart';
import '../../planner/model/assignment_estimate.dart';
import '../../planner/model/assignment_rule.dart';
import '../bloc/node_cubit.dart';
import '../bloc/schedule_prefs_cubit.dart';
import '../model/node.dart';
import 'schedule_fields.dart';

final _sheetDueFormat = DateFormat('EEE, MMM d');

/// Unified schedule entry: the same sheet from the Tasks tile and from
/// Nodes. Day mode edits the due date inline; Time mode always goes
/// through the calendar — a time is a calendar event picked visually,
/// never typed inline. The last saved granularity is remembered
/// per-device; the Day/Time toggle switches after opening.
Future<void> showScheduleSheet(
  BuildContext context, {
  required String nodeId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: _ScheduleSheet(nodeId: nodeId),
    ),
  );
}

class _ScheduleSheet extends StatefulWidget {
  final String nodeId;

  const _ScheduleSheet({required this.nodeId});

  @override
  State<_ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends State<_ScheduleSheet> {
  late ScheduleDraft _draft;
  bool _ready = false;
  String? _title;

  @override
  void initState() {
    super.initState();
    Node? node;
    try {
      node = context.read<NodeCubit>().byId(widget.nodeId);
    } catch (_) {}
    if (node == null) {
      _draft = ScheduleDraft();
      _ready = false;
      return;
    }
    ScheduleGranularity fallback = ScheduleGranularity.day;
    try {
      fallback = context.read<SchedulePrefsCubit>().state.lastUsed;
    } catch (_) {}
    _title = node.title;
    _draft = ScheduleDraft(
      due: node.schedule?.due,
      fixed: node.schedule?.isFixed ?? false,
      blockStart: node.schedule?.start,
      blockEnd: node.schedule?.end,
      mode: SchedulePrefsCubit.initialFor(
        schedule: node.schedule,
        fallback: fallback,
      ),
    );
    _ready = true;
  }

  AssignmentEstimate _estimateFor(BuildContext context, Node node) {
    var rules = const <AssignmentRule>[];
    var efforts = const <AssignmentTypeEffort>[];
    try {
      rules = context.read<AssignmentRulesCubit>().state;
    } catch (_) {}
    try {
      efforts = context.read<AssignmentEstimatesCubit>().state;
    } catch (_) {}
    return resolveAssignmentEstimate(
      node: node,
      rules: rules,
      efforts: efforts,
    );
  }

  int _snapMinutes(BuildContext context) {
    try {
      return context.read<SettingsCubit>().state.snapMinutes;
    } catch (_) {
      return 15;
    }
  }

  void _pickOnCalendar() {
    Node? node;
    try {
      node = context.read<NodeCubit>().byId(widget.nodeId);
    } catch (_) {}
    if (node == null) return;
    CalendarDraftCubit? drafts;
    NavigationCubit? navigation;
    ScaffoldMessengerState? messenger;
    try {
      drafts = context.read<CalendarDraftCubit>();
    } catch (_) {}
    try {
      navigation = context.read<NavigationCubit>();
    } catch (_) {}
    try {
      messenger = ScaffoldMessenger.of(context);
    } catch (_) {}
    final seed = draftSeedFromNode(
      node,
      estimate: _estimateFor(context, node),
      snapMinutes: _snapMinutes(context),
    );
    try {
      context.read<SchedulePrefsCubit>().setGranularity(
            ScheduleGranularity.timed,
          );
    } catch (_) {}
    Navigator.of(context).pop();
    if (drafts == null) return;
    drafts.requestDraft(seed);
    try {
      navigation?.setPage(PlannerPage.calendar);
    } catch (_) {}
    messenger?.showSnackBar(
      const SnackBar(
        content: Text(
          'Pick a time on the calendar — nothing is saved until you press Add.',
        ),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _save() {
    NodeCubit nodes;
    try {
      nodes = context.read<NodeCubit>();
    } catch (_) {
      Navigator.of(context).pop();
      return;
    }
    final node = nodes.byId(widget.nodeId);
    if (node == null) {
      Navigator.of(context).pop();
      return;
    }
    // Day mode only: due date inline, existing calendar block preserved.
    // Time mode never saves here — it goes through the calendar (which
    // writes the block) or clears the block below.
    final existing = node.schedule;
    final due = _draft.due;
    final fixed = _draft.fixed;
    ScheduleFacet? schedule;
    if (due != null || fixed) {
      schedule = ScheduleFacet(
        due: due,
        start: existing?.start,
        end: existing?.end,
        allDay: existing?.allDay ?? false,
        isFixed: fixed,
      );
    } else if (existing?.hasCalendarBlock ?? false) {
      schedule = ScheduleFacet(
        start: existing!.start,
        end: existing.end,
        allDay: existing.allDay,
      );
    }
    final error = nodes.updateNode(node.copyWith(
      schedule: schedule,
      clearSchedule: schedule == null,
    ));
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
      return;
    }
    try {
      context
          .read<SchedulePrefsCubit>()
          .setGranularity(ScheduleGranularity.day);
    } catch (_) {}
    Navigator.of(context).pop();
  }

  void _clearBlock() {
    NodeCubit nodes;
    try {
      nodes = context.read<NodeCubit>();
    } catch (_) {
      Navigator.of(context).pop();
      return;
    }
    final node = nodes.byId(widget.nodeId);
    if (node == null) {
      Navigator.of(context).pop();
      return;
    }
    final existing = node.schedule;
    ScheduleFacet? schedule;
    if (existing?.due != null || (existing?.isFixed ?? false)) {
      schedule = ScheduleFacet(
        due: existing?.due,
        isFixed: existing?.isFixed ?? false,
      );
    }
    final error = nodes.updateNode(node.copyWith(
      schedule: schedule,
      clearSchedule: schedule == null,
    ));
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
      return;
    }
    try {
      context
          .read<SchedulePrefsCubit>()
          .setGranularity(ScheduleGranularity.timed);
    } catch (_) {}
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const SizedBox.shrink();
    Node live;
    try {
      live = context.watch<NodeCubit>().byId(widget.nodeId) ??
          context.read<NodeCubit>().byId(widget.nodeId)!;
    } catch (_) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final due = live.schedule?.due;
    final hasBlock = live.schedule?.hasCalendarBlock ?? false;
    final statusLine = due == null && !hasBlock
        ? 'Not scheduled'
        : [
            if (due != null) 'Due ${_sheetDueFormat.format(due)}',
            if (hasBlock) 'Timed block set',
          ].join(' · ');
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Schedule', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              _title ?? live.title,
              style: theme.textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(statusLine, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            ScheduleFields(
              draft: _draft,
              onChanged: (next) => setState(() => _draft = next),
              onPickCalendar: _pickOnCalendar,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                if (_draft.mode == ScheduleGranularity.day) ...[
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _save,
                    child: const Text('Save'),
                  ),
                ] else if (_draft.hasBlock) ...[
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _clearBlock,
                    child: const Text('Clear time'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
