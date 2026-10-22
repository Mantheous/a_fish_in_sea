import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../planner/service/weekly_time_report.dart';

final _statsDayFormat = DateFormat('EEE');
final _statsTimeFormat = DateFormat('h:mm a');

/// Toggl-style week totals keyed by goal plus the week's timesheet list.
/// Read-only: starting/stopping timers still happens from Home, Tasks,
/// the calendar tiles, and Day review — this is where the logged time
/// lands, grouped the way Toggl groups by project.
class TimeByGoalCard extends StatelessWidget {
  final WeeklyTimeReport report;

  const TimeByGoalCard({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Time by goal',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Week total ${formatWeeklyDuration(report.weekTotal)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (report.byGoal.isEmpty)
              const Text(
                'No tracked time this week — start a timer from Home, '
                'Tasks, or the calendar.',
              ),
            for (final goal in report.byGoal)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: goalColorFor(goal.goalId),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(goal.title)),
                    Text(
                      formatWeeklyDuration(goal.total),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
              ),
            if (report.entries.isNotEmpty) ...[
              const Divider(height: 24),
              Text('Timesheet',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final entry in report.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        margin: const EdgeInsets.only(top: 4),
                        decoration: BoxDecoration(
                          color: goalColorFor(entry.goalId),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(entry.title),
                            Text(
                              '${_statsDayFormat.format(entry.start)} '
                              '${_statsTimeFormat.format(entry.start)} – '
                              '${_statsTimeFormat.format(entry.end)} · '
                              '${entry.goalTitle}'
                              '${entry.live ? ' · recording' : ''}',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: entry.live
                                        ? Theme.of(context)
                                            .colorScheme
                                            .primary
                                        : null,
                                    fontWeight: entry.live
                                        ? FontWeight.w600
                                        : null,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(formatWeeklyDuration(entry.duration)),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
