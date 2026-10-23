import '../nodes/model/node.dart';
import 'fitness_models.dart';

/// Pure helpers that feed synced watch values into goal progress.
/// No I/O here: the server proxy fetches from Strava, and callers pass
/// the samples in. Kept pure so unit tests can use mocked samples.

/// Measured value for [node]'s fitness target from synced samples.
/// Sleep goals sum sleep minutes; activity-minutes goals sum activity
/// durations; activity-count goals count activities.
double fitnessActualForNode(
  Node node,
  List<FitnessActivity> activities, {
  List<SleepSample> sleep = const [],
}) {
  final fitness = node.fitness;
  if (fitness == null) return 0.0;
  switch (fitness.metric) {
    case FitnessMetric.sleepMinutes:
      return sleep.fold<double>(0, (sum, s) => sum + s.minutes);
    case FitnessMetric.activityMinutes:
      return activities.fold<double>(0, (sum, a) => sum + a.minutes);
    case FitnessMetric.activityCount:
      return activities.length.toDouble();
  }
}

/// Local calendar-day start for [value].
DateTime fitnessDayStart(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// The day a goal measures: its due day (or start day) when scheduled,
/// else today. Mirrors [applyWorkoutActivity]'s day choice so a workout
/// auto-report and its goal agree on which day they belong to.
DateTime fitnessGoalDay(Node node, {DateTime? now}) {
  final day = node.schedule?.due ??
      node.schedule?.start ??
      (now ?? DateTime.now());
  return fitnessDayStart(day);
}

/// Measured value for [node] on the day it tracks (see [fitnessGoalDay]).
/// Activity goals sum/count only that day's activities; sleep goals take
/// the night whose morning is that day.
double fitnessActualForNodeOnDay(
  Node node,
  List<FitnessActivity> activities, {
  List<SleepSample> sleep = const [],
  DateTime? now,
}) {
  final day = fitnessGoalDay(node, now: now);
  return fitnessActualForNode(
    node,
    [
      for (final a in activities)
        if (fitnessDayStart(a.start) == day) a,
    ],
    sleep: [
      for (final s in sleep)
        if (fitnessDayStart(s.date) == day) s,
    ],
  );
}

/// Per-node measured values for every fitness-backed node in [nodes],
/// ready for `progressForest(fitnessActualByNodeId: ...)`.
Map<String, double> fitnessActualsByNodeId(
  List<Node> nodes,
  List<FitnessActivity> activities, {
  List<SleepSample> sleep = const [],
  DateTime? now,
}) =>
    {
      for (final n in nodes)
        if (n.fitness != null)
          n.id: fitnessActualForNodeOnDay(
            n,
            activities,
            sleep: sleep,
            now: now,
          ),
    };

/// Auto-report for workout-marked tasks: the first watch activity on the
/// node's due/calendar day fills [actualStart]/[actualEnd]. Returns the
/// updated node, or the original when there is nothing to fill (not a
/// workout, already reported, or no activity on that day).
Node applyWorkoutActivity(
  Node node,
  List<FitnessActivity> activities,
) {
  // A running timer means the user is reporting this workout themselves:
  // never stamp watch times under live tracking.
  if (!node.isWorkout ||
      node.hasReported ||
      node.timerStartedAt != null ||
      activities.isEmpty) {
    return node;
  }
  final day = node.schedule?.due ??
      node.schedule?.start ??
      node.actualStart ??
      node.createdAt;
  final dayStart = DateTime(day.year, day.month, day.day);
  FitnessActivity? match;
  for (final a in activities) {
    final aDay = DateTime(a.start.year, a.start.month, a.start.day);
    if (aDay == dayStart) {
      match = a;
      break;
    }
  }
  if (match == null) return node;
  if (!match.end.isAfter(match.start)) return node;
  return node.copyWith(actualStart: match.start, actualEnd: match.end);
}

/// Batch variant: applies [applyWorkoutActivity] to every workout node.
/// Non-workout and already-reported nodes pass through untouched.
List<Node> applyWorkoutActivities(
  List<Node> nodes,
  List<FitnessActivity> activities,
) =>
    [for (final n in nodes) applyWorkoutActivity(n, activities)];
