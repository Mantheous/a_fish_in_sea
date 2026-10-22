import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../common/undo/undo_bar.dart';
import '../../navigation/view/app_drawer.dart';
import '../../nodes/bloc/node_cubit.dart';
import '../../planner/bloc/assignment_estimates_cubit.dart';
import '../../planner/bloc/assignment_rules_cubit.dart';
import '../../planner/bloc/calendar_cubit.dart';
import '../../planner/bloc/feed_cubit.dart';
import '../../planner/model/assignment_estimate.dart';
import '../../planner/model/assignment_rule.dart';
import '../../planner/service/weekly_time_report.dart';
import '../bloc/places_cubit.dart';
import '../bloc/reporting_cubit.dart';
import '../bloc/tracking_cubit.dart';
import '../model/reported_entry.dart';
import '../reporting_logic.dart';
import '../service/location_service.dart';
import '../stats_logic.dart';
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
  StatsRangePreset _preset = StatsRangePreset.thisWeek;

  List<DateTime> get _weekDays {
    final monday = _day.subtract(Duration(days: _day.weekday - 1));
    return [for (var i = 0; i < 7; i++) monday.add(Duration(days: i))];
  }

  DateTime get _weekStart {
    final monday = _day.subtract(Duration(days: _day.weekday - 1));
    return DateTime(monday.year, monday.month, monday.day);
  }

  @override
  Widget build(BuildContext context) {
    // Watch every cubit the report reads. Without these the numbers go
    // stale: a recorded session would not appear until something else
    // happened to rebuild the page.
    final tracking = context.watch<TrackingCubit>();
    final calendar = context.watch<CalendarCubit>();
    final feeds = context.watch<FeedCubit>();
    final nodes = context.watch<NodeCubit>().state;
    final reported = context.watch<ReportingCubit>().state;
    final placeNames = {
      for (final p in context.watch<PlacesCubit>().state) p.id: p.name,
    };
    final rules = context.readOrNull<AssignmentRulesCubit>()?.state ??
        const <AssignmentRule>[];
    final efforts =
        context.readOrNull<AssignmentEstimatesCubit>()?.state ??
            const <AssignmentTypeEffort>[];

    final range = statsRangeFor(_preset);

    // One planned-slice pass per day in the range. Cached by day key so
    // the range totals and the week place chart can never disagree about
    // what was on the calendar.
    final sliceCache = <String, List<PlannedSlice>>{};
    final rangeDays = [
      for (var i = 0; i < range.days; i++)
        range.start.add(Duration(days: i)),
    ];
    for (final day in rangeDays) {
      sliceCache.putIfAbsent(
        dayKey(day),
        () => daySlices(calendar, feeds, day),
      );
    }
    final plannedInRange = <PlannedSlice>[
      for (final day in rangeDays) ...sliceCache[dayKey(day)]!,
    ];

    final reportedInRange = <ReportedEntry>[];
    for (final entries in reported.values) {
      for (final entry in entries) {
        if (!range.contains(entry.start)) continue;
        reportedInRange.add(entry);
      }
    }

    final timeReport = buildAssignmentTimeReport(
      range: range,
      plannedSlices: plannedInRange,
      nodes: nodes,
      rules: rules,
      efforts: efforts,
      reportedEntries: reportedInRange,
    );
    final goalReport = buildGoalRangeReport(range: range, nodes: nodes);

    // The place/today cards keep the week the user is browsing, which is
    // not always the same week as the selected range.
    final weekStats = [
      for (final d in _weekDays)
        _statsFor(
          d,
          tracking: tracking,
          calendar: calendar,
          feeds: feeds,
          cache: sliceCache,
        ),
    ];
    final todayStats = weekStats[_day.weekday - 1];
    final weekAttended = weekStats.fold<int>(0, (sum, s) => sum + s.attendedMin);
    final weekPlanned = weekStats.fold<int>(0, (sum, s) => sum + s.plannedMin);
    // Toggl-style week totals by goal: every stopped/running timer and
    // accepted manual entry in the week, credited to the root goal above
    // its backing node (or "(no goal)"). Pure read of existing timer
    // fields — no new state.
    final weekTimeReport = buildWeeklyTimeReport(
      nodes: nodes,
      events: calendar.state,
      reportsByDay: reported,
      weekStart: _weekStart,
    );

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _RangePicker(
          preset: _preset,
          onChanged: (p) => setState(() => _preset = p),
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
        _TimeAccountingCard(report: timeReport),
        const SizedBox(height: 8),
        _ClassTimeCard(report: timeReport),
        const SizedBox(height: 8),
        _TypeTimeCard(report: timeReport),
        const SizedBox(height: 8),
        _DayTimeCard(report: timeReport),
        const SizedBox(height: 8),
        _GoalsCard(report: goalReport),
        const SizedBox(height: 8),
        DayPicker(
          day: _day,
          onChanged: (d) => setState(() => _day = d),
        ),
        const SizedBox(height: 4),
        _PlacesCard(
          stats: todayStats,
          placeNames: placeNames,
          weekAttended: weekAttended,
          weekPlanned: weekPlanned,
        ),
        _TimeByGoalCard(report: weekTimeReport),
        if (!LocationService.supported)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'GPS is not available on this device — Day review still '
                'accepts manual test points.',
              ),
            ),
          ),
        const SizedBox(height: 24),
      ],
    );
  }

  DayStats _statsFor(
    DateTime day, {
    required TrackingCubit tracking,
    required CalendarCubit calendar,
    required FeedCubit feeds,
    required Map<String, List<PlannedSlice>> cache,
  }) {
    final places = context.read<PlacesCubit>().state;
    final points = tracking.pointsOnDay(day);
    final planned = cache.putIfAbsent(
      dayKey(day),
      () => daySlices(calendar, feeds, day),
    );
    return computeDayStats(
      planned: planned,
      dwells: clusterDwells(points, places),
    );
  }
}

/// Reads a cubit that is not always provided (standalone widget tests
/// pump this page without them), returning null when it is absent.
extension _OptionalCubit on BuildContext {
  T? readOrNull<T extends Object>() {
    try {
      return read<T>();
    } catch (_) {
      return null;
    }
  }
}

class _RangePicker extends StatelessWidget {
  final StatsRangePreset preset;
  final ValueChanged<StatsRangePreset> onChanged;

  const _RangePicker({required this.preset, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SegmentedButton<StatsRangePreset>(
        segments: [
          for (final preset in StatsRangePreset.values)
            ButtonSegment(
              value: preset,
              label: Text(preset.label),
            ),
        ],
        selected: {preset},
        showSelectedIcon: false,
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}

final _rangeDateFormat = DateFormat('EEE, MMM d');
final _longDateFormat = DateFormat('MMM d');

String _rangeLabel(StatsRange range) {
  final lastDay = range.end.subtract(const Duration(days: 1));
  if (range.days <= 7) {
    return '${_rangeDateFormat.format(range.start)} – ${_rangeDateFormat.format(lastDay)}';
  }
  return '${_longDateFormat.format(range.start)} – ${_longDateFormat.format(lastDay)}';
}

// ── Time accounting ────────────────────────────────────────────────────

class _TimeAccountingCard extends StatelessWidget {
  final AssignmentTimeReport report;

  const _TimeAccountingCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accuracy = report.estimateAccuracy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _rangeLabel(report.range),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (report.assignmentsCompleted > 0)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.check, size: 16),
                    label: Text('${report.assignmentsCompleted} done'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _BigNumber(
                  value: describeMinutes(report.trackedMinutes),
                  caption: 'recorded',
                  color: theme.colorScheme.primary,
                ),
                _DividerDot(),
                _BigNumber(
                  value: describeMinutes(report.plannedMinutes),
                  caption: 'planned, not recorded',
                ),
                _DividerDot(),
                _BigNumber(
                  value: describeMinutes(report.unaccountedMinutes),
                  caption: 'not accounted for',
                  color: theme.colorScheme.error,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Recorded work is a timer you ran. Planned is on the calendar '
              'with no timer. Not accounted for is waking time on days you '
              'did something, with neither — rest and transit do not count '
              'against you on a day you recorded nothing.',
              style: theme.textTheme.bodySmall,
            ),
            if (report.trackedNotPlannedMinutes > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${describeMinutes(report.trackedNotPlannedMinutes)} of that '
                'was off-plan — work you did that was never scheduled.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.tertiary,
                ),
              ),
            ],
            if (accuracy != null) ...[
              const SizedBox(height: 8),
              _AccuracyLine(accuracy: accuracy),
            ],
            if (!report.hasData) const _EmptyHint(
              'Nothing recorded in this range yet. Start a timer on an '
              'assignment and it lands here.',
            ),
          ],
        ),
      ),
    );
  }
}

class _AccuracyLine extends StatelessWidget {
  final double accuracy;

  const _AccuracyLine({required this.accuracy});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // accuracy = estimated / recorded. Below 1 means the work took longer
    // than the estimate.
    final pct = (accuracy * 100).round();
    final verdict = accuracy > 1.25
        ? 'You beat your estimates — the app is over-booking time.'
        : accuracy < 0.8
            ? 'Work is taking longer than estimated. Raising them frees the schedule.'
            : 'Estimates are close to reality.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Estimates ran at $pct% of recorded time.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.secondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(verdict, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

class _BigNumber extends StatelessWidget {
  final String value;
  final String caption;
  final Color? color;

  const _BigNumber({
    required this.value,
    required this.caption,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            caption,
            style: theme.textTheme.labelSmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _DividerDot extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 40,
        color: Theme.of(context).dividerColor,
        margin: const EdgeInsets.symmetric(horizontal: 8),
      );
}

class _EmptyHint extends StatelessWidget {
  final String text;

  const _EmptyHint(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
      );
}

// ── Time by class ─────────────────────────────────────────────────────

class _ClassTimeCard extends StatelessWidget {
  final AssignmentTimeReport report;

  const _ClassTimeCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = report.byClass.where((g) => g.totalMinutes > 0).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Time by class', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Recorded sessions plus scheduled blocks with no timer, '
              'per class.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (groups.isEmpty)
              const _EmptyHint('No class time in this range.')
            else
              for (final group in groups)
                _GroupBar(
                  label: group.label,
                  minutes: group.totalMinutes,
                  value: group.totalMinutes,
                  max: groups.first.totalMinutes,
                  trailing: Text(
                    describeMinutes(group.totalMinutes),
                    style: theme.textTheme.labelMedium,
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _GroupBar extends StatelessWidget {
  final String label;
  final int minutes;
  final int value;
  final int max;
  final Widget trailing;

  const _GroupBar({
    required this.label,
    required this.minutes,
    required this.value,
    required this.max,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              trailing,
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 8,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Time by assignment type ───────────────────────────────────────────

class _TypeTimeCard extends StatelessWidget {
  final AssignmentTimeReport report;

  const _TypeTimeCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = report.byType.where((g) => g.totalMinutes > 0).toList();
    final accuracy = report.estimateAccuracy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Time by assignment type', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Grouped by the repeating types the rules use — every "Video '
              'Quiz 3.1" and "Video Quiz 3.4" counts once.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (groups.isEmpty)
              const _EmptyHint('No classified assignment time in this range.')
            else
              for (final group in groups)
                _GroupBar(
                  label: group.label,
                  minutes: group.totalMinutes,
                  value: group.totalMinutes,
                  max: groups.first.totalMinutes,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        describeMinutes(group.totalMinutes),
                        style: theme.textTheme.labelMedium,
                      ),
                      if (accuracy != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          '${(accuracy * 100).round()}% of est',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            const SizedBox(height: 8),
            Text(
              'More recordings make these sharper — each timer you run '
              'updates the estimate and the time of day you usually start.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Per-day chart ─────────────────────────────────────────────────────

class _DayTimeCard extends StatelessWidget {
  final AssignmentTimeReport report;

  const _DayTimeCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = report.days;
    if (days.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Per day', style: theme.textTheme.titleMedium),
              const _EmptyHint('Nothing on the calendar in this range.'),
            ],
          ),
        ),
      );
    }
    final maxMinutes = days
        .map((d) => d.coveredMinutes)
        .fold(0, (a, b) => a > b ? a : b);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Per day', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Recorded (solid) plus planned with no timer (faded).',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: BarChart(
                BarChartData(
                  maxY: (maxMinutes / 60).ceilToDouble() * 60,
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 34,
                        getTitlesWidget: (value, _) => Text(
                          '${(value / 60).round()}h',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, _) {
                          final i = value.toInt();
                          if (i < 0 || i >= days.length) {
                            return const SizedBox.shrink();
                          }
                          return Text(
                            DateFormat('d').format(days[i].day),
                            style: theme.textTheme.labelSmall,
                          );
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
                    for (var i = 0; i < days.length; i++)
                      BarChartGroupData(
                        x: i,
                        barRods: [
                          BarChartRodData(
                            toY: days[i].trackedMinutes.toDouble(),
                            width: 16,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          BarChartRodData(
                            // Net planned (no-timer) time only, not stacked
                            // on top of tracked: with overlap already
                            // removed this rod fits under the covered axis.
                            toY: days[i].plannedMinutes.toDouble(),
                            width: 16,
                            borderRadius: BorderRadius.circular(3),
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.35),
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
    );
  }
}

// ── Goals ─────────────────────────────────────────────────────────────

class _GoalsCard extends StatelessWidget {
  final GoalRangeReport report;

  const _GoalsCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Goals', style: theme.textTheme.titleMedium),
                ),
                if (report.completed.isNotEmpty)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.emoji_events_outlined, size: 16),
                    label: Text('${report.completed.length} finished'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Checklists, money, time and review targets — everything '
              'that is not imported homework.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (report.completed.isNotEmpty) ...[
              for (final row in report.completed.take(8))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.check_circle_outline, size: 20),
                  title: Text(row.node.title),
                  subtitle: Text(
                    '${goalKindLabel(row.kind)}'
                    '${row.completedAt == null ? '' : ' · ${_rangeDateFormat.format(row.completedAt!)}'}',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              if (report.completed.length > 8)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '+${report.completed.length - 8} more finished',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              const SizedBox(height: 4),
            ],
            if (report.checklistTotal > 0)
              _GoalMetric(
                label: 'Checklist items',
                value: '${report.checklistDone} of ${report.checklistTotal}',
                progress: report.checklistPct,
              ),
            if (report.effortGoalCount > 0)
              _GoalMetric(
                label: report.effortGoalCount == 1
                    ? 'Time goal'
                    : '${report.effortGoalCount} time goals',
                value:
                    '${describeMinutes(report.effortLoggedMinutes)} of ${describeMinutes(report.effortTargetMinutes)}',
                progress: report.effortPct,
              ),
            if (report.moneyGoalCount > 0)
              _GoalMetric(
                label: report.moneyGoalCount == 1
                    ? 'Money goal'
                    : '${report.moneyGoalCount} money goals',
                value: '\$${report.moneyActual.toStringAsFixed(0)} of '
                    '\$${report.moneyTarget.toStringAsFixed(0)}',
                // A $0 target has no ratio; show empty, not NaN.
                progress: report.moneyPct ?? 0,
              ),
            if (report.ankiGoalCount > 0)
              _GoalMetric(
                label: report.ankiGoalCount == 1
                    ? 'Review goal'
                    : '${report.ankiGoalCount} review goals',
                value:
                    '${report.ankiReviews} of ${report.ankiTarget} cards',
                progress: report.ankiTarget == 0
                    ? 0
                    : (report.ankiReviews / report.ankiTarget)
                        .clamp(0.0, 1.0),
              ),
            if (!report.hasData)
              const _EmptyHint(
                'No goals yet. Anything without a class feed shows up here '
                '— a checklist, a savings target, a weekly time goal.',
              ),
            if (report.overdue > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${report.overdue} goal${report.overdue == 1 ? '' : 's'} '
                'past their deadline.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GoalMetric extends StatelessWidget {
  final String label;
  final String value;
  final double progress;

  const _GoalMetric({
    required this.label,
    required this.value,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label, style: theme.textTheme.bodyMedium),
              ),
              Text(value, style: theme.textTheme.labelMedium),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Places (kept from the old page) ───────────────────────────────────

class _PlacesCard extends StatelessWidget {
  final DayStats stats;
  final Map<String, String> placeNames;
  final int weekAttended;
  final int weekPlanned;

  const _PlacesCard({
    required this.stats,
    required this.placeNames,
    required this.weekAttended,
    required this.weekPlanned,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Where you were', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '${(stats.onTaskPct * 100).round()}% on task today',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            Text(
              '${stats.attendedMin} of ${stats.plannedMin} planned minutes · '
              'this week $weekAttended of $weekPlanned',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (stats.minutesPerPlace.isEmpty)
              const Text('No time at saved places yet.')
            else
              for (final e in stats.minutesPerPlace.entries)
                Text(
                  '${placeNames[e.key] ?? 'Somewhere'}: ${e.value} min',
                ),
          ],
        ),
      ),
    );
  }
}
