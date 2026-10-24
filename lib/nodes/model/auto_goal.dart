import 'package:equatable/equatable.dart';

import 'package:a_fish_in_sea/finances/model/time_scale.dart';

/// Where an automated goal's numbers come from.
///
/// One facet covers every source instead of adding a new `NodeRuleKind`
/// (or a new facet) per metric: [tasks] reads the node DAG and its
/// recorded/calendar time, and [money] reads imported transactions.
///
/// A future health/watch integration plugs in here as another source; the
/// evaluator's inputs are already injected, so adding one does not change
/// persisted goals.
enum AutoSource { tasks, money }

/// How [AutoSource] rows are combined inside a period.
enum AutoMetric {
  /// Sum of minutes (recorded time, else elapsed calendar-block time).
  minutes,

  /// Mean minutes per active day in the period.
  averageMinutes,

  /// Completed tasks or matching transactions.
  count,

  /// Distinct local days with a completion.
  days,

  /// Tasks source only: share of matching tasks that are done, 0–100.
  percentDone,

  /// Money source only: sum of spending in the period.
  amount,
}

/// Target direction. [atLeast] is the classic "reach N" goal; [atMost] is
/// a cap ("spend less than $20") that is complete while under target.
enum AutoComparison { atLeast, atMost }

/// Which slice of the graph a task/money goal reads.
///
/// [subtree] means the goal's own descendants (assigned tasks/events or
/// transactions assigned under it), so a repeated event assigned to the
/// goal reports without extra configuration. [all] means every matching
/// node/transaction in the store, which is what homework-wide or
/// class-wide goals need.
enum AutoScope { subtree, all }

/// Generic automated goal: a selector plus an aggregator plus a rolling
/// window. Persisted additively on [Node]; old payloads without the key
/// load as non-automated.
///
/// Examples this one shape covers:
/// - 7 h scripture study / week: tasks, minutes, weekly, subtree
/// - 15 h work / week: same with a work calendar series under the goal
/// - under 30 h homework / week: tasks, minutes, weekly, all, homework
/// - class-scoped homework: add [classKeys]
/// - run 5 days / week: tasks, days, weekly, run occurrences under it
/// - spend under $20 / week: money, amount, weekly, [moneyCategories]
/// - finish Monday's homework by Saturday: tasks, percentDone, weekly,
///   [horizonDays] = 2
class AutoFacet extends Equatable {
  final AutoSource source;
  final AutoMetric metric;
  final double target;
  final AutoComparison comparison;
  final TimeScale period;
  final int? customPeriodDays;

  /// Task/money scope.
  final AutoScope scope;

  /// Tasks source: keep only imported homework. [classKeys] narrows it
  /// further to one or more classes, keyed the same way the Tasks filters
  /// key them (`classLabel` first, then `classId`).
  final bool homeworkOnly;
  final List<String> classKeys;

  /// Money source: case-insensitive substrings matched against the
  /// transaction category. Empty means every spending transaction.
  final List<String> moneyCategories;

  /// Tasks source + [AutoMetric.percentDone]: how many days ahead count
  /// as "must be done". Null/0 uses the rolling period window instead.
  final int? horizonDays;

  const AutoFacet({
    this.source = AutoSource.tasks,
    this.metric = AutoMetric.minutes,
    this.target = 0,
    this.comparison = AutoComparison.atLeast,
    this.period = TimeScale.weekly,
    this.customPeriodDays,
    this.scope = AutoScope.subtree,
    this.homeworkOnly = false,
    this.classKeys = const [],
    this.moneyCategories = const [],
    this.horizonDays,
  });

  bool get isConfigured => target > 0;

  /// The unit a raw [target] is expressed in.
  String get unit => switch (metric) {
    AutoMetric.minutes || AutoMetric.averageMinutes => 'minutes',
    AutoMetric.amount => 'dollars',
    AutoMetric.percentDone => 'percent',
    AutoMetric.count || AutoMetric.days => 'count',
  };

  AutoFacet copyWith({
    AutoSource? source,
    AutoMetric? metric,
    double? target,
    AutoComparison? comparison,
    TimeScale? period,
    int? customPeriodDays,
    bool clearCustomPeriodDays = false,
    AutoScope? scope,
    bool? homeworkOnly,
    List<String>? classKeys,
    List<String>? moneyCategories,
    int? horizonDays,
    bool clearHorizonDays = false,
  }) => AutoFacet(
    source: source ?? this.source,
    metric: metric ?? this.metric,
    target: target ?? this.target,
    comparison: comparison ?? this.comparison,
    period: period ?? this.period,
    customPeriodDays: clearCustomPeriodDays
        ? null
        : (customPeriodDays ?? this.customPeriodDays),
    scope: scope ?? this.scope,
    homeworkOnly: homeworkOnly ?? this.homeworkOnly,
    classKeys: classKeys ?? this.classKeys,
    moneyCategories: moneyCategories ?? this.moneyCategories,
    horizonDays: clearHorizonDays ? null : (horizonDays ?? this.horizonDays),
  );

  factory AutoFacet.fromJson(Map<String, dynamic> json) {
    final source = _enumOr(AutoSource.values, json['source'], AutoSource.tasks);
    final metric = _enumOr(
      AutoMetric.values,
      json['metric'],
      defaultMetricFor(source),
    );
    final rawTarget = json['target'];
    final rawDays = json['customPeriodDays'];
    final rawHorizon = json['horizonDays'];
    return AutoFacet(
      source: source,
      metric: metric,
      target: rawTarget is num ? rawTarget.toDouble().clamp(0, 1e9) : 0,
      comparison: _enumOr(
        AutoComparison.values,
        json['comparison'],
        AutoComparison.atLeast,
      ),
      period: _enumOr(TimeScale.values, json['period'], TimeScale.weekly),
      customPeriodDays: rawDays is num ? rawDays.toInt().clamp(1, 36500) : null,
      scope: _enumOr(AutoScope.values, json['scope'], AutoScope.subtree),
      homeworkOnly: json['homeworkOnly'] == true,
      classKeys: _stringList(json['classKeys']),
      moneyCategories: _stringList(json['moneyCategories']),
      horizonDays: rawHorizon is num ? rawHorizon.toInt().clamp(1, 3650) : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'source': source.name,
    'metric': metric.name,
    'target': target,
    'comparison': comparison.name,
    'period': period.name,
    'customPeriodDays': customPeriodDays,
    'scope': scope.name,
    'homeworkOnly': homeworkOnly,
    'classKeys': classKeys,
    'moneyCategories': moneyCategories,
    'horizonDays': horizonDays,
  };

  @override
  List<Object?> get props => [
    source,
    metric,
    target,
    comparison,
    period,
    customPeriodDays,
    scope,
    homeworkOnly,
    // Sorted for stable equality across restores.
    [...classKeys]..sort(),
    [...moneyCategories]..sort(),
    horizonDays,
  ];
}

/// Default metric when switching source in the editor.
AutoMetric defaultMetricFor(AutoSource source) => switch (source) {
  AutoSource.tasks => AutoMetric.minutes,
  AutoSource.money => AutoMetric.amount,
};

/// Metrics the editor offers for [source]. Kept next to the model so a new
/// source cannot be added without deciding what it can measure.
List<AutoMetric> autoMetricsFor(AutoSource source) => switch (source) {
  AutoSource.tasks => const [
    AutoMetric.minutes,
    AutoMetric.count,
    AutoMetric.days,
    AutoMetric.percentDone,
  ],
  AutoSource.money => const [AutoMetric.amount, AutoMetric.count],
};

/// Human labels shared by the editor and goal tiles.
String autoSourceLabel(AutoSource source) => switch (source) {
  AutoSource.tasks => 'Tasks & calendar',
  AutoSource.money => 'Money (transactions)',
};

String autoMetricLabel(AutoMetric metric) => switch (metric) {
  AutoMetric.minutes => 'Minutes',
  AutoMetric.averageMinutes => 'Average minutes',
  AutoMetric.count => 'Count',
  AutoMetric.days => 'Active days',
  AutoMetric.percentDone => 'Done',
  AutoMetric.amount => 'Amount spent',
};

String autoComparisonLabel(AutoComparison comparison) => switch (comparison) {
  AutoComparison.atLeast => 'Reach at least',
  AutoComparison.atMost => 'Stay under',
};

String autoScopeLabel(AutoScope scope) => switch (scope) {
  AutoScope.subtree => 'This goal’s work',
  AutoScope.all => 'Everything that matches',
};

T _enumOr<T extends Enum>(List<T> values, Object? raw, T fallback) {
  if (raw is! String) return fallback;
  for (final value in values) {
    if (value.name == raw) return value;
  }
  return fallback;
}

List<String> _stringList(Object? raw) {
  if (raw is! List) return const [];
  final out = <String>[];
  for (final item in raw) {
    if (item is String && item.trim().isNotEmpty) {
      out.add(item.trim());
    }
    if (out.length >= 32) break;
  }
  return out;
}
