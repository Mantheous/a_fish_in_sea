import 'package:a_fish_in_sea/fitness/fitness_models.dart';
import 'package:a_fish_in_sea/fitness/fitness_sync.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_progress.dart';
import 'package:flutter_test/flutter_test.dart';

final _day = DateTime(2026, 10, 5, 9);

void main() {
  test('Node fitness facet round-trips, legacy loads untracked', () {
    final node = Node(
      id: 'n1',
      title: 'Sleep 8h',
      createdAt: _day,
      isWorkout: true,
      fitness: const FitnessFacet(
        metric: FitnessMetric.sleepMinutes,
        targetValue: 480,
      ),
    );
    expect(Node.fromJson(node.toJson()), node);
    final legacy = Map<String, dynamic>.from(node.toJson())
      ..remove('fitness')
      ..remove('isWorkout');
    final restored = Node.fromJson(legacy);
    expect(restored.fitness, isNull);
    expect(restored.isWorkout, isFalse);
  });

  test('unknown fitness enum values fall back instead of throwing', () {
    final bad = {
      'metric': 'renamed-value',
      'targetValue': 60,
      'provider': 'other-watch',
    };
    final facet = FitnessFacet.fromJson(bad);
    expect(facet.metric, FitnessMetric.activityMinutes);
    expect(facet.provider, FitnessProvider.strava);
  });

  test('mocked watch activity auto-reports a workout task', () {
    final task = Node(
      id: 'n2',
      title: 'Morning run',
      createdAt: _day,
      schedule: ScheduleFacet(due: _day),
      isWorkout: true,
    );
    final activity = FitnessActivity(
      id: 'a1',
      type: 'run',
      start: DateTime(2026, 10, 5, 7),
      end: DateTime(2026, 10, 5, 7, 30),
    );
    final reported = applyWorkoutActivity(task, [activity]);
    expect(reported.actualStart, activity.start);
    expect(reported.actualEnd, activity.end);
    expect(reported.reportedDuration?.inMinutes, 30);
    // Non-workouts and already-reported nodes pass through untouched.
    expect(
      applyWorkoutActivity(
        task.copyWith(isWorkout: false),
        [activity],
      ).hasReported,
      isFalse,
    );
    expect(
      applyWorkoutActivity(reported, [activity]),
      reported,
    );
  });

  test('workout with no activity on its day stays unreported', () {
    final task = Node(
      id: 'n2b',
      title: 'Morning run',
      createdAt: _day,
      schedule: ScheduleFacet(due: _day),
      isWorkout: true,
    );
    // Activity is on a different day: the node must pass through
    // unchanged instead of filling with the unrelated activity.
    final otherDay = FitnessActivity(
      id: 'a9',
      type: 'run',
      start: DateTime(2026, 10, 6, 7),
      end: DateTime(2026, 10, 6, 7, 30),
    );
    final untouched = applyWorkoutActivity(task, [otherDay]);
    expect(untouched.hasReported, isFalse);
    expect(untouched.actualStart, isNull);
    expect(untouched.actualEnd, isNull);
    // Empty list also passes through.
    expect(applyWorkoutActivity(task, const []).hasReported, isFalse);
  });

  test('mocked sleep sample drives a sleep goal progress', () {
    final node = Node(
      id: 'n3',
      title: 'Sleep 8h',
      createdAt: _day,
      fitness: const FitnessFacet(
        metric: FitnessMetric.sleepMinutes,
        targetValue: 480,
      ),
    );
    final actual = fitnessActualForNode(
      node,
      const [],
      sleep: [SleepSample(date: _day, minutes: 420)],
    );
    expect(actual, 420);
    expect(fitnessProgress(node.fitness!, actual), closeTo(0.875, 1e-9));
    final forest = progressForest(
      [node],
      fitnessActualByNodeId: {node.id: actual},
    );
    expect(forest[node.id], closeTo(0.875, 1e-9));
  });

  test('activity count goal counts synced activities', () {
    final node = Node(
      id: 'n4',
      title: 'Work out 3x',
      createdAt: _day,
      fitness: const FitnessFacet(
        metric: FitnessMetric.activityCount,
        targetValue: 3,
      ),
    );
    final activities = [
      FitnessActivity(
        id: 'a1',
        type: 'run',
        start: _day,
        end: _day.add(const Duration(minutes: 30)),
      ),
      FitnessActivity(
        id: 'a2',
        type: 'ride',
        start: _day.add(const Duration(days: 1)),
        end: _day.add(const Duration(days: 1, minutes: 45)),
      ),
    ];
    final actual = fitnessActualForNode(node, activities);
    expect(actual, 2);
    expect(
      progressForest(
        [node],
        fitnessActualByNodeId: {node.id: actual},
      )[node.id],
      closeTo(2 / 3, 1e-9),
    );
  });

  test('goal actuals only count the goal day, not the whole window', () {
    final goal = Node(
      id: 'n5',
      title: 'Run 30 min today',
      createdAt: _day,
      schedule: ScheduleFacet(due: _day),
      fitness: const FitnessFacet(
        metric: FitnessMetric.activityMinutes,
        targetValue: 30,
      ),
    );
    final activities = [
      FitnessActivity(
        id: 'today',
        type: 'run',
        start: DateTime(2026, 10, 5, 7),
        end: DateTime(2026, 10, 5, 7, 30),
      ),
      FitnessActivity(
        id: 'yesterday',
        type: 'run',
        start: DateTime(2026, 10, 4, 7),
        end: DateTime(2026, 10, 4, 8),
      ),
    ];
    expect(
      fitnessActualForNodeOnDay(goal, activities, now: _day),
      30,
    );
    // The loose helper still sums whatever it is handed.
    expect(fitnessActualForNode(goal, activities), 90);

    // Two goals on different days read different slices of the window.
    final yesterdayGoal = Node(
      id: 'n6',
      title: 'Run 60 min',
      createdAt: _day,
      schedule: ScheduleFacet(due: DateTime(2026, 10, 4, 9)),
      fitness: const FitnessFacet(
        metric: FitnessMetric.activityMinutes,
        targetValue: 60,
      ),
    );
    final byId = fitnessActualsByNodeId(
      [goal, yesterdayGoal],
      activities,
      now: _day,
    );
    expect(byId['n5'], 30);
    expect(byId['n6'], 60);
  });

  test('sleep actuals match the goal day', () {
    final goal = Node(
      id: 'n7',
      title: 'Sleep 8h',
      createdAt: _day,
      schedule: ScheduleFacet(due: _day),
      fitness: const FitnessFacet(
        metric: FitnessMetric.sleepMinutes,
        targetValue: 480,
      ),
    );
    expect(
      fitnessActualsByNodeId(
        [goal],
        const [],
        sleep: [
          SleepSample(date: _day, minutes: 420),
          SleepSample(date: DateTime(2026, 10, 4, 9), minutes: 300),
        ],
        now: _day,
      )[goal.id],
      420,
    );
  });
}
