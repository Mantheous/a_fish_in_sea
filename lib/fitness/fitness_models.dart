import 'package:equatable/equatable.dart';

/// Watch provider. Strava is the connector the server speaks: Garmin,
/// Coros, Wahoo and Polar all push their workouts into Strava, and any
/// Strava user can register a free API app. Garmin stays in the enum so
/// facets stored by the old scaffold payloads still load.
enum FitnessProvider { garmin, strava }

/// What a fitness-backed goal measures. Sleep and activity were the two
/// metrics the issue asked for: hours of sleep and counts/time of
/// activities. Unknown stored values fall back to [activityMinutes] so a
/// rename never wipes the facet.
enum FitnessMetric { sleepMinutes, activityMinutes, activityCount }

/// Fitness target on a goal node. Additive and nullable on [Node]: old
/// payloads without it load as untracked. [targetValue] is minutes for
/// [sleepMinutes]/[activityMinutes] and a count for [activityCount].
class FitnessFacet extends Equatable {
  final FitnessMetric metric;
  final double targetValue;
  final FitnessProvider provider;

  const FitnessFacet({
    required this.metric,
    required this.targetValue,
    this.provider = FitnessProvider.strava,
  });

  FitnessFacet copyWith({
    FitnessMetric? metric,
    double? targetValue,
    FitnessProvider? provider,
  }) =>
      FitnessFacet(
        metric: metric ?? this.metric,
        targetValue: targetValue ?? this.targetValue,
        provider: provider ?? this.provider,
      );

  factory FitnessFacet.fromJson(Map<String, dynamic> json) => FitnessFacet(
        metric: FitnessMetric.values.firstWhere(
          (e) => e.name == json['metric'],
          orElse: () => FitnessMetric.activityMinutes,
        ),
        targetValue: (json['targetValue'] as num?)?.toDouble() ?? 0.0,
        provider: FitnessProvider.values.firstWhere(
          (e) => e.name == json['provider'],
          orElse: () => FitnessProvider.strava,
        ),
      );

  Map<String, dynamic> toJson() => {
        'metric': metric.name,
        'targetValue': targetValue,
        'provider': provider.name,
      };

  @override
  List<Object?> get props => [metric, targetValue, provider];
}

/// One watch activity (run, ride, swim, …). Minimal shape the client
/// needs to auto-report workout tasks: start/end feed progress.
class FitnessActivity extends Equatable {
  final String id;
  final String type;
  final DateTime start;
  final DateTime end;
  final FitnessProvider provider;

  const FitnessActivity({
    required this.id,
    required this.type,
    required this.start,
    required this.end,
    this.provider = FitnessProvider.strava,
  });

  double get minutes =>
      end.isAfter(start) ? end.difference(start).inMinutes.toDouble() : 0.0;

  factory FitnessActivity.fromJson(Map<String, dynamic> json) =>
      FitnessActivity(
        id: (json['id'] as String?) ?? '',
        type: (json['type'] as String?) ?? 'workout',
        start: DateTime.tryParse(json['start'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        end: DateTime.tryParse(json['end'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        provider: FitnessProvider.values.firstWhere(
          (e) => e.name == json['provider'],
          orElse: () => FitnessProvider.strava,
        ),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'provider': provider.name,
      };

  @override
  List<Object?> get props => [id, type, start, end, provider];
}

/// One night of sleep. [date] is the morning the night belongs to;
/// [minutes] is total sleep minutes for that night.
class SleepSample extends Equatable {
  final DateTime date;
  final double minutes;

  const SleepSample({required this.date, required this.minutes});

  factory SleepSample.fromJson(Map<String, dynamic> json) => SleepSample(
        date: DateTime.tryParse(json['date'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        minutes: (json['minutes'] as num?)?.toDouble() ?? 0.0,
      );

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'minutes': minutes,
      };

  @override
  List<Object?> get props => [date, minutes];
}
