import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../common/time/local_date.dart';
import '../../nodes/model/node.dart';
import '../bloc/assignment_estimates_cubit.dart';
import '../bloc/assignment_rules_cubit.dart';
import '../model/assignment_estimate.dart';
import '../model/assignment_rule.dart';
import '../model/task_assignee.dart';

/// Small pieces shared by task tiles: time/due formatting, the learned
/// estimate line, due-today cues, and the assignee avatar row.

final _timeFormat = DateFormat('h:mm a');
final _dueFormat = DateFormat('EEE, MMM d');

/// "3:00 PM" for tile work lines.
String formatTaskTime(DateTime time) => _timeFormat.format(time);

/// "Wed, Sep 10" for tile due lines.
String formatTaskDue(DateTime due) => _dueFormat.format(due);

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
