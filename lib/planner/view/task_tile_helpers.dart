import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../common/time/local_date.dart';
import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/model/node.dart';
import '../../nodes/service/node_calendar.dart';
import '../../nodes/service/node_progress.dart';
import '../bloc/assignment_estimates_cubit.dart';
import '../bloc/assignment_rules_cubit.dart';
import '../model/assignment_estimate.dart';
import '../model/assignment_rule.dart';
import '../model/task_assignee.dart';

/// Small pieces shared by task tiles: time/due formatting, the work line,
/// the learned estimate line, due-today cues, and the assignee avatar row.

final _timeFormat = DateFormat('h:mm a');
final _dueFormat = DateFormat('EEE, MMM d');

/// "3:00 PM" for tile work lines.
String formatTaskTime(DateTime time) => _timeFormat.format(time);

/// "Wed, Sep 10" for tile due lines.
String formatTaskDue(DateTime due) => _dueFormat.format(due);

/// "today", "tomorrow", or "Mon, Oct 26" for a planned slot's day.
///
/// The day is what makes a plan visibly land *before* its due date; the
/// nearest days use the words people actually say.
String formatPlannedDay(DateTime day, DateTime now) {
  final distance = localDayDistance(now, day);
  if (distance == 0) return 'today';
  if (distance == 1) return 'tomorrow';
  return _dueFormat.format(day);
}

/// "Planned Mon, Oct 26, 3:00 PM – 4:00 PM" for a tile's planned line.
/// Slots that cross midnight name both days so the end time is never
/// ambiguous.
String formatPlannedSlot(DateTime start, DateTime end, DateTime now) {
  final startTime = formatTaskTime(start);
  final endTime = formatTaskTime(end);
  final startDay = formatPlannedDay(start, now);
  if (isSameLocalDay(start, end)) {
    return 'Planned $startDay, $startTime – $endTime';
  }
  return 'Planned $startDay, $startTime – '
      '${formatPlannedDay(end, now)}, $endTime';
}

/// Estimate for one assignment: the rule's explicit number, then the
/// learned average for its classified type, then the node's own time
/// target, then a plain hour.
///
/// Both cubits are optional so standalone widget tests (and any embed of
/// the tile) keep working without them.
AssignmentEstimate estimateForNode(BuildContext context, Node node) {
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
String estimateLine(AssignmentEstimate estimate) {
  final minutes = describeMinutes(estimate.minutes);
  final start = estimate.preferredStartMinute;
  if (start == null) return 'Est ~$minutes';
  return 'Est ~$minutes, ${describeTimeOfDay(start)}';
}

/// The tile's second line: failure, the running timer, reported vs planned
/// time, the next planned slot (named with its day), the homework estimate,
/// or money progress — in that order.
///
/// [plan] is the node's next upcoming slot when the parent list hoisted it;
/// when the node's own block is no longer upcoming it still shows that block
/// so a missed plan stays visible.
String? taskWorkLine(
  BuildContext context,
  Node node, {
  required DateTime now,
  PlannedSlot? plan,
  Map<String, Node>? indexById,
  Map<String, List<Node>>? indexByParent,
}) {
  if (node.status == NodeStatus.failed) return 'Failed';
  if (node.isTracking) return 'Recording…';
  final reported = node.reportedDuration;
  if (node.hasReported && reported != null) {
    final planned = node.schedule?.plannedDuration;
    return planned == null
        ? 'Reported ${reported.inMinutes}m'
        : 'Reported ${reported.inMinutes}m (planned ${planned.inMinutes}m)';
  }
  if (plan != null) return formatPlannedSlot(plan.start, plan.end, now);
  final block = node.schedule;
  // All-day blocks are dates a thing happens (a feed's open..due window, an
  // all-day placement), not planned work time — the same rule the calendar
  // and the Planned filter use. They must not read as "Planned 11:59 PM".
  if (block != null && block.hasCalendarBlock && !block.allDay) {
    return formatPlannedSlot(block.start!, block.end!, now);
  }
  if (node.isHomework) return estimateLine(estimateForNode(context, node));
  final money = node.money;
  if (money != null) {
    final actual = (indexById != null && indexByParent != null)
        ? moneyActualForNodeIndexed(
            node,
            byId: indexById,
            byParent: indexByParent,
          )
        : moneyActualForNode(node, context.read<NodeCubit>().state);
    return '\$${actual.toStringAsFixed(2)} / '
        '\$${money.effectiveTarget.toStringAsFixed(2)}';
  }
  return null;
}

bool isDueToday(DateTime due, DateTime now) => isSameLocalDay(due, now);

/// Readable orange for "due today" cues in either brightness.
Color dueTodayColor(ThemeData theme) => theme.brightness == Brightness.dark
    ? Colors.orange.shade300
    : Colors.orange.shade800;

class AssigneeLine extends StatelessWidget {
  final List<TaskAssignee> assignees;

  const AssigneeLine({super.key, required this.assignees});

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
