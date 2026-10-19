import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../common/undo/undo_bar.dart';
import '../../navigation/view/app_drawer.dart';
import '../../nodes/bloc/node_cubit.dart';
import '../../planner/bloc/calendar_cubit.dart';
import '../../planner/bloc/feed_cubit.dart';
import '../../planner/service/weekly_time_report.dart';
import '../bloc/places_cubit.dart';
import '../bloc/reporting_cubit.dart';
import '../bloc/tracking_cubit.dart';
import '../reporting_logic.dart';
import '../service/location_service.dart';
import 'day_review_screen.dart';
import 'places_sheet.dart';

class StatsPage extends StatelessWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stats'),
        actions: const [UndoRedoActions()],
      ),
      drawer: const AppDrawer(),
      body: const _StatsBody(),
    );
  }
}

class _StatsBody extends StatefulWidget {
  const _StatsBody();

  @override
  State<_StatsBody> createState() => _StatsBodyState();
}

final _statsDayFormat = DateFormat('EEE');
final _statsTimeFormat = DateFormat('h:mm a');

/// Toggl-style week totals keyed by goal plus the week's timesheet list.
/// Read-only: starting/stopping timers still happens from Home, Tasks,
/// the calendar tiles, and Day review — this is where the logged time
/// lands, grouped the way Toggl groups by project.
class _TimeByGoalCard extends StatelessWidget {
  final WeeklyTimeReport report;

  const _TimeByGoalCard({required this.report});

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

class _StatsBodyState extends State<_StatsBody> {
  DateTime _day = DateTime.now();

  List<DateTime> get _weekDays {
    final monday = _day.subtract(Duration(days: _day.weekday - 1));
    return [for (var i = 0; i < 7; i++) monday.add(Duration(days: i))];
  }

  DateTime get _weekStart {
    final monday = _day.subtract(Duration(days: _day.weekday - 1));
    return DateTime(monday.year, monday.month, monday.day);
  }

  DayStats _statsFor(
    BuildContext context,
    DateTime day,
    Map<String, List<PlannedSlice>> cache,
  ) {
    final calendar = context.read<CalendarCubit>();
    final feeds = context.read<FeedCubit>();
    final places = context.read<PlacesCubit>().state;
    // Indexed O(1) per day after one O(p) bucket pass (see TrackingCubit).
    final points = context.read<TrackingCubit>().pointsOnDay(day);
    final planned = cache.putIfAbsent(
      dayKey(day),
      () => daySlices(calendar, feeds, day),
    );
    return computeDayStats(
      planned: planned,
      dwells: clusterDwells(points, places),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Subscribe to every cubit _statsFor reads via context.read, otherwise
    // the week chart goes stale (e.g. new points don't update it until a
    // place is added/removed).
    context.watch<TrackingCubit>();
    context.watch<CalendarCubit>();
    context.watch<FeedCubit>();
    final nodeState = context.watch<NodeCubit>().state;
    final reportState = context.watch<ReportingCubit>().state;
    final cache = <String, List<PlannedSlice>>{};
    final weekStats = [for (final d in _weekDays) _statsFor(context, d, cache)];
    final todayStats = weekStats[_day.weekday - 1];
    final placeNames = {for (final p in context.watch<PlacesCubit>().state) p.id: p.name};
    final weekAttended =
        weekStats.fold<int>(0, (sum, s) => sum + s.attendedMin);
    final weekPlanned =
        weekStats.fold<int>(0, (sum, s) => sum + s.plannedMin);
    // Toggl-style week totals by goal: every stopped/running timer and
    // accepted manual entry in the week, credited to the root goal above
    // its backing node (or "(no goal)"). Pure read of existing timer
    // fields — no new state.
    final timeReport = buildWeeklyTimeReport(
      nodes: nodeState,
      events: context.read<CalendarCubit>().state,
      reportsByDay: reportState,
      weekStart: _weekStart,
    );

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        DayPicker(
          day: _day,
          onChanged: (d) => setState(() => _day = d),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const DayReviewScreen(),
                  ),
                ),
                icon: const Icon(Icons.map_outlined),
                label: const Text('Day review'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => showPlacesSheet(context),
                icon: const Icon(Icons.place_outlined),
                label: const Text('Places'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Today', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  '${(todayStats.onTaskPct * 100).round()}% on task',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  '${todayStats.attendedMin} of ${todayStats.plannedMin} planned minutes',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                if (todayStats.minutesPerPlace.isEmpty)
                  const Text('No time at saved places yet.'),
                for (final e in todayStats.minutesPerPlace.entries)
                  Text(
                    '${placeNames[e.key] ?? 'Somewhere'}: ${e.value} min',
                  ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('This week',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  '$weekAttended of $weekPlanned planned minutes',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 160,
                  child: BarChart(
                    BarChartData(
                      maxY: 100,
                      titlesData: FlTitlesData(
                        leftTitles: const AxisTitles(
                          sideTitles: SideTitles(
                              showTitles: true, reservedSize: 32),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            getTitlesWidget: (value, _) {
                              const labels = [
                                'M', 'T', 'W', 'T', 'F', 'S', 'S'
                              ];
                              final i = value.toInt();
                              if (i < 0 || i > 6) {
                                return const SizedBox.shrink();
                              }
                              return Text(labels[i]);
                            },
                          ),
                        ),
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                      ),
                      barGroups: [
                        for (var i = 0; i < 7; i++)
                          BarChartGroupData(
                            x: i,
                            barRods: [
                              BarChartRodData(
                                toY: weekStats[i].onTaskPct * 100,
                                width: 16,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        _TimeByGoalCard(report: timeReport),
        if (!LocationService.supported)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'GPS is not available on this device — Day review still accepts manual test points.',
              ),
            ),
          ),
      ],
    );
  }
}
