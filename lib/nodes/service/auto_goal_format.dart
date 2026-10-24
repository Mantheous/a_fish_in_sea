import 'package:a_fish_in_sea/finances/model/time_scale.dart';

import '../model/node.dart';

/// Human wording for automated-goal readings. Kept apart from the
/// evaluator so tiles, the editor, and tests share one vocabulary without
/// pulling transaction/fitness types into the formatting path.
String autoPeriodLabel(AutoFacet facet) => switch (facet.period) {
  TimeScale.daily => 'today',
  TimeScale.weekly => 'this week',
  TimeScale.biweekly => 'these two weeks',
  TimeScale.monthly => 'this month',
  TimeScale.quarterly => 'this quarter',
  TimeScale.yearly => 'this year',
  TimeScale.custom => 'every ${facet.customPeriodDays ?? 30} days',
};

/// "6h 20m" / "45m" / "0m".
String formatAutoMinutes(double value) {
  final total = value.round();
  final hours = total ~/ 60;
  final minutes = total % 60;
  if (hours <= 0) return '${minutes}m';
  if (minutes == 0) return '${hours}h';
  return '${hours}h ${minutes}m';
}

/// One value in its metric's natural unit, for tiles and summaries.
String formatAutoValue(AutoMetric metric, double value) => switch (metric) {
  AutoMetric.minutes || AutoMetric.averageMinutes => formatAutoMinutes(value),
  AutoMetric.amount => '\$${value.toStringAsFixed(2)}',
  AutoMetric.percentDone => '${value.round()}%',
  AutoMetric.count || AutoMetric.days => '${value.round()}',
};

/// Short description of what an automated goal reads, used in the editor
/// and empty-state copy.
String describeAutoGoal(AutoFacet facet) {
  final parts = <String>[
    autoSourceLabel(facet.source),
    autoMetricLabel(facet.metric).toLowerCase(),
    autoPeriodLabel(facet),
  ];
  if (facet.source == AutoSource.tasks && facet.homeworkOnly) {
    parts.add('homework only');
  }
  if (facet.source == AutoSource.tasks && facet.classKeys.isNotEmpty) {
    parts.add(facet.classKeys.join(', '));
  }
  if (facet.source == AutoSource.activities && facet.activityTypes.isNotEmpty) {
    parts.add(facet.activityTypes.join(', '));
  }
  if (facet.source == AutoSource.money && facet.moneyCategories.isNotEmpty) {
    parts.add(facet.moneyCategories.join(', '));
  }
  return parts.join(' · ');
}
