import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/planner/bloc/assignment_estimates_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/assignment_rules_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/model/assignment_estimate.dart';

/// Stops a recording timer (if running) and asks what to do next.
/// The stop settles both stores: a linked calendar event's timer stops
/// with the same reported interval, so the sheet and the calendar agree.
Future<void> stopNodeAndFinish(BuildContext context, String nodeId) async {
  Node? node;
  try {
    node = context.read<NodeCubit>().byId(nodeId);
  } catch (_) {
    return;
  }
  if (node == null) return;
  if (node.isTracking) {
    try {
      NodeEventLink.stopNodeTrackingAligned(
        context.read<NodeCubit>(),
        context.read<CalendarCubit>(),
        nodeId,
      );
    } catch (_) {
      try {
        context.read<NodeCubit>().stopTracking(nodeId);
      } catch (_) {}
    }
  }
  if (!context.mounted) return;
  await showNodeFinishSheet(context, nodeId: nodeId);
}

Future<void> showNodeFinishSheet(
  BuildContext context, {
  required String nodeId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => _FinishSheet(nodeId: nodeId),
  );
}

/// Schedules a follow-up the same way assignments are scheduled from the
/// Tasks page: seeds a calendar draft and hands the user to the calendar
/// to pick the time visually, instead of typing a date/time here.
///
/// The seed keeps the node's current block (same time-of-day, same length,
/// one day later) or falls back to the estimate flow when there is no
/// block to continue. Nothing is saved until the user presses Add on the
/// calendar — the same guarantee the Tasks "Add to calendar" snackbar
/// makes.
Future<void> showFollowUpScheduler(
  BuildContext context, {
  required String nodeId,
}) {
  Node? node;
  try {
    node = context.read<NodeCubit>().byId(nodeId);
  } catch (_) {
    return Future.value();
  }
  if (node == null) return Future.value();

  // Resolve the estimate/snap the same way the Tasks page does, best
  // effort: standalone contexts may not provide every cubit.
  AssignmentEstimate? estimate;
  try {
    final rules = context.read<AssignmentRulesCubit>().state;
    var efforts = const <AssignmentTypeEffort>[];
    try {
      efforts = context.read<AssignmentEstimatesCubit>().state;
    } catch (_) {}
    estimate = resolveAssignmentEstimate(
      node: node,
      rules: rules,
      efforts: efforts,
    );
  } catch (_) {}
  var snap = 15;
  try {
    snap = context.read<SettingsCubit>().state.snapMinutes;
  } catch (_) {}

  final seed =
      draftSeedForFollowUp(node, estimate: estimate, snapMinutes: snap);

  CalendarDraftCubit? drafts;
  try {
    drafts = context.read<CalendarDraftCubit>();
  } catch (_) {}
  NavigationCubit? navigation;
  try {
    navigation = context.read<NavigationCubit>();
  } catch (_) {}
  ScaffoldMessengerState? messenger;
  try {
    messenger = ScaffoldMessenger.of(context);
  } catch (_) {}

  // Read everything above before closing the sheet: the caller's context
  // belongs to the sheet being dismissed.
  try {
    if (ModalRoute.of(context) is ModalBottomSheetRoute) {
      Navigator.of(context).pop();
    }
  } catch (_) {}

  if (drafts == null) return Future.value();
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
  return Future.value();
}

class _FinishSheet extends StatelessWidget {
  final String nodeId;

  const _FinishSheet({required this.nodeId});

  @override
  Widget build(BuildContext context) {
    Node? node;
    try {
      node = context.watch<NodeCubit>().byId(nodeId);
    } catch (_) {}
    if (node == null) {
      // The sheet can outlive its node (deleted elsewhere / synced away):
      // offer an explicit way out — there is no swipe on desktop/web.
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('This node was deleted.'),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );
    }
    final theme = Theme.of(context);
    final timeFormat = DateFormat('h:mm a');
    final reported = node.reportedDuration;
    final reportedLine = reported != null &&
            node.actualStart != null &&
            node.actualEnd != null
        ? 'Recorded ${timeFormat.format(node.actualStart!)} – '
            '${timeFormat.format(node.actualEnd!)} '
            '(${reported.inMinutes == 0 ? '${reported.inSeconds}s' : '${reported.inMinutes}m'})'
        : 'Recording saved.';
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Work session saved',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(node.title, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 4),
            Text(reportedLine, style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(
              'These change the goal\'s status, not just this session.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                try {
                  final nodes = context.read<NodeCubit>();
                  final current = nodes.byId(nodeId);
                  if (current != null && !current.isDone) {
                    NodeEventLink.toggleNodeDone(
                      nodes,
                      context.read<CalendarCubit>(),
                      nodeId,
                    );
                  }
                } catch (_) {}
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Mark goal complete'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                try {
                  NodeEventLink.setNodeFailed(
                    context.read<NodeCubit>(),
                    context.read<CalendarCubit>(),
                    nodeId,
                    true,
                  );
                } catch (_) {}
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.cancel_outlined, size: 18),
              label: const Text('Mark goal failed'),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => showFollowUpScheduler(context, nodeId: nodeId),
              icon: const Icon(Icons.schedule, size: 18),
              label: const Text('Schedule follow-up'),
            ),
            const SizedBox(height: 4),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    );
  }
}

