import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../common/undo/undo_bar.dart';
import '../../navigation/view/app_drawer.dart';
import '../../planner/bloc/calendar_cubit.dart';
import '../../planner/bloc/feed_cubit.dart';
import '../bloc/places_cubit.dart';
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

class _StatsBodyState extends State<_StatsBody> {
  DateTime _day = DateTime.now();

  List<DateTime> get _weekDays {
    final monday = _day.subtract(Duration(days: _day.weekday - 1));
    return [for (var i = 0; i < 7; i++) monday.add(Duration(days: i))];
  }

  DayStats _statsFor(
    BuildContext context,
    DateTime day,
    Map<String, List<PlannedSlice>> cache,
  ) {
    final calendar = context.read<CalendarCubit>();
    final feeds = context.read<FeedCubit>();
    final places = context.read<PlacesCubit>().state;
    final points = context.read<TrackingCubit>().state.pointsOnDay(day);
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
    final cache = <String, List<PlannedSlice>>{};
    final weekStats = [for (final d in _weekDays) _statsFor(context, d, cache)];
    final todayStats = weekStats[_day.weekday - 1];
    final placeNames = {for (final p in context.watch<PlacesCubit>().state) p.id: p.name};
    final weekAttended =
        weekStats.fold<int>(0, (sum, s) => sum + s.attendedMin);
    final weekPlanned =
        weekStats.fold<int>(0, (sum, s) => sum + s.plannedMin);

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
        if (!LocationService.supported && !kIsWeb)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Location recording is supported on Android and iOS only.',
              ),
            ),
          ),
      ],
    );
  }
}
