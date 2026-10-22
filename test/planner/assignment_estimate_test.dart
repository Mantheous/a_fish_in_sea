import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/model/assignment_estimate.dart';
import 'package:a_fish_in_sea/planner/model/assignment_rule.dart';
import 'package:flutter_test/flutter_test.dart';

/// A homework node that has been worked on, so the learner has something
/// to learn from.
Node worked({
  String id = 'node:hw1',
  String feedId = 'math290',
  String classLabel = 'MATH 290',
  String title = 'Video Quiz 3.1',
  DateTime? startedAt,
  int minutes = 30,
}) {
  final start = startedAt ?? DateTime(2026, 10, 5, 19);
  return Node(
    id: id,
    title: title,
    createdAt: DateTime(2026, 9, 1),
    feedId: feedId,
    classId: feedId,
    classLabel: classLabel,
    sourceEventId: 'evt:$id',
    schedule: ScheduleFacet(due: start.add(const Duration(days: 2))),
    actualStart: start,
    actualEnd: start.add(Duration(minutes: minutes)),
    timerStartedAt: start,
  );
}

void main() {
  const dayMinutes = 24 * 60;

  group('collectEffortSamples', () {
    test('reads a recorded homework session', () {
      final samples = collectEffortSamples([
        worked(startedAt: DateTime(2026, 10, 5, 19), minutes: 42),
      ]);
      expect(samples, hasLength(1));
      expect(samples.single.minutes, 42);
      expect(samples.single.templateKey, 'video quiz');
      expect(samples.single.feedId, 'math290');
    });

    test('ignores nodes with no report, no class, or zero minutes', () {
      expect(collectEffortSamples(const []), isEmpty);
      expect(
        collectEffortSamples([
          Node(id: 'a', title: 'Video Quiz', createdAt: DateTime(2026)),
        ]),
        isEmpty,
      );
      expect(
        collectEffortSamples([
          Node(
            id: 'a',
            title: 'Video Quiz',
            createdAt: DateTime(2026),
            actualStart: DateTime(2026, 10, 1, 9),
            // Same instant as the start: not a duration.
            actualEnd: DateTime(2026, 10, 1, 9),
          ),
        ]),
        isEmpty,
      );
      // A non-homework node's sessions are goal work, not assignment work.
      expect(
        collectEffortSamples([
          Node(
            id: 'a',
            title: 'Read scriptures',
            createdAt: DateTime(2026),
            actualStart: DateTime(2026, 10, 1, 9),
            actualEnd: DateTime(2026, 10, 1, 10),
          ),
        ]),
        isEmpty,
      );
    });
  });

  group('learnEffortIndex', () {
    test('groups by feed + classified type, not by title', () {
      final index = learnEffortIndex([
        worked(id: 'a', title: 'Video Quiz 3.1', minutes: 30),
        worked(id: 'b', title: 'Video Quiz 3.4b', minutes: 45),
        worked(id: 'c', title: 'Video Quiz', minutes: 60),
      ]);
      expect(index, hasLength(1));
      final e = index.single;
      expect(e.groupKey, 'math290|video quiz');
      expect(e.samples, 3);
      expect(e.totalMinutes, 135);
      expect(e.minutes, [30, 45, 60]);
      expect(e.minMinutes, 30);
      expect(e.maxMinutes, 60);
    });

    test('keeps types from different classes apart', () {
      final index = learnEffortIndex([
        worked(id: 'a', feedId: 'math290', classLabel: 'MATH 290'),
        worked(id: 'b', feedId: 'stat230', classLabel: 'STAT 230'),
      ]);
      expect(index, hasLength(2));
      expect(index.map((e) => e.groupKey).toSet(), {
        'math290|video quiz',
        'stat230|video quiz',
      });
    });

    test('median wins over the mean so one long night does not skew it', () {
      final index = learnEffortIndex([
        worked(id: 'a', minutes: 30),
        worked(id: 'b', minutes: 30),
        worked(id: 'c', minutes: 30),
        worked(id: 'd', minutes: 400),
      ]);
      expect(index.single.medianMinutes, 30);
      // The mean (122) would have over-estimated.
      expect(index.single.estimateMinutes, 30);
      expect(index.single.maxMinutes, 400);
    });

    test('is idempotent — rebuilding twice yields the same index', () {
      final nodes = [
        worked(id: 'a', minutes: 30),
        worked(id: 'b', minutes: 45),
      ];
      final first = learnEffortIndex(nodes);
      final second = learnEffortIndex(nodes, existing: first);
      expect(second, hasLength(1));
      expect(second.single.samples, first.single.samples);
      expect(second.single.minutes, first.single.minutes);
      expect(second.single.totalMinutes, first.single.totalMinutes);
    });

    test('keeps a quiet group alive through an empty rebuild', () {
      final before = learnEffortIndex([worked(id: 'a', minutes: 30)]);
      final after = learnEffortIndex([], existing: before);
      expect(after, hasLength(1));
      expect(after.single.estimateMinutes, 30);
    });

    test('bounds the rolling window', () {
      final nodes = [
        for (var i = 0; i < 40; i++)
          worked(id: 'a$i', minutes: 20 + i),
      ];
      final index = learnEffortIndex(nodes);
      expect(index.single.minutes.length, assignmentEffortWindow);
      // The oldest samples fell out, so the window holds the last 30.
      expect(index.single.minutes.first, 30);
      // The lifetime totals still see every session.
      expect(index.single.samples, 40);
      expect(index.single.totalMinutes, (20 + 59) * 40 ~/ 2);
    });
  });

  group('habitual start time', () {
    test('median of the recorded starts', () {
      final index = learnEffortIndex([
        worked(id: 'a', startedAt: DateTime(2026, 10, 1, 18, 30)),
        worked(id: 'b', startedAt: DateTime(2026, 10, 2, 19, 0)),
        worked(id: 'c', startedAt: DateTime(2026, 10, 3, 19, 30)),
      ]);
      expect(index.single.preferredStartMinute, 19 * 60);
    });

    test('treats late night and early morning as neighbours', () {
      final index = learnEffortIndex([
        worked(id: 'a', startedAt: DateTime(2026, 10, 1, 23, 40)),
        worked(id: 'b', startedAt: DateTime(2026, 10, 2, 0, 20)),
      ]);
      // 23:40 and 00:20 are 40 minutes apart, not 23 hours apart — the
      // midpoint is midnight, and neither start is more than 20 minutes
      // away from it.
      final start = index.single.preferredStartMinute!;
      final away = (start - (23 * 60 + 40)).abs();
      final circular = away > dayMinutes / 2 ? dayMinutes - away : away;
      expect(circular, lessThanOrEqualTo(20));
      expect(describeTimeOfDay(start), 'around 12 AM');
    });
  });

  group('resolveAssignmentEstimate', () {
    test('prefers the rule\'s explicit number', () {
      final nodes = [worked(id: 'a', minutes: 30)];
      final index = learnEffortIndex(nodes);
      final rules = [
        AssignmentRule(
          id: 'r1',
          feedId: 'math290',
          templateKey: 'video quiz',
          displayName: 'Video Quiz',
          dueOffsetDays: -2,
          estimateMinutes: 15,
          createdAt: DateTime(2026, 10, 1),
        ),
      ];
      final estimate = resolveAssignmentEstimate(
        node: nodes.single,
        rules: rules,
        efforts: index,
      );
      expect(estimate.minutes, 15);
      expect(estimate.source, AssignmentEstimateSource.rule);
    });

    test('falls back to the learned average', () {
      final nodes = [worked(id: 'a', minutes: 30)];
      final index = learnEffortIndex(nodes);
      final estimate = resolveAssignmentEstimate(
        node: nodes.single,
        efforts: index,
      );
      expect(estimate.minutes, 30);
      expect(estimate.source, AssignmentEstimateSource.learned);
      expect(estimate.preferredStartMinute, 19 * 60);
    });

    test('falls back to the effort target, then an hour', () {
      final effortNode = Node(
        id: 'g',
        title: 'Video Quiz 1',
        createdAt: DateTime(2026),
        feedId: 'math290',
        effort: const EffortFacet(targetMinutes: 75),
      );
      final estimate = resolveAssignmentEstimate(node: effortNode);
      expect(estimate.minutes, 75);
      expect(estimate.source, AssignmentEstimateSource.effort);

      final plain = Node(
        id: 'p',
        title: 'Read the chapter',
        createdAt: DateTime(2026),
        feedId: 'math290',
      );
      expect(resolveAssignmentEstimate(node: plain).minutes, 60);
      expect(
        resolveAssignmentEstimate(node: plain).source,
        AssignmentEstimateSource.fallback,
      );
    });

    test('never invents a habit for an unclassified one-off', () {
      final index = learnEffortIndex([worked(id: 'a', minutes: 30)]);
      final plain = Node(
        id: 'p',
        title: 'One-off reflection paper',
        createdAt: DateTime(2026),
        feedId: 'math290',
      );
      expect(
        resolveAssignmentEstimate(node: plain, efforts: index)
            .preferredStartMinute,
        isNull,
      );
    });

    test('a rule never matches across classes', () {
      final node = worked(id: 'a', feedId: 'stat230');
      final rules = [
        AssignmentRule(
          id: 'r1',
          feedId: 'math290',
          templateKey: 'video quiz',
          displayName: 'Video Quiz',
          dueOffsetDays: 0,
          estimateMinutes: 15,
          createdAt: DateTime(2026, 10, 1),
        ),
      ];
      expect(
        resolveAssignmentEstimate(node: node, rules: rules).minutes,
        60,
      );
    });
  });

  group('formatting', () {
    test('describeMinutes', () {
      expect(describeMinutes(0), '0m');
      expect(describeMinutes(45), '45m');
      expect(describeMinutes(60), '1h');
      expect(describeMinutes(90), '1h 30m');
      expect(describeMinutes(120), '2h');
    });

    test('describeTimeOfDay', () {
      expect(describeTimeOfDay(19 * 60), 'around 7 PM');
      expect(describeTimeOfDay(9 * 60), 'around 9 AM');
      expect(describeTimeOfDay(9 * 60 + 30), 'around 9:30 AM');
      expect(describeTimeOfDay(12 * 60), 'around 12 PM');
      expect(describeTimeOfDay(0), 'around 12 AM');
    });

    test('snapMinuteOfDay rounds to the setting', () {
      expect(snapMinuteOfDay(19 * 60 + 41, 15), 19 * 60 + 45);
      expect(snapMinuteOfDay(19 * 60 + 44, 15), 19 * 60 + 45);
      expect(snapMinuteOfDay(19 * 60 + 46, 15), 19 * 60 + 45);
      expect(snapMinuteOfDay(19 * 60, 30), 19 * 60);
      expect(snapMinuteOfDay(10, 0), 10);
    });

    test('snapMinuteOfDay clamps instead of wrapping past midnight', () {
      // A start snapped past 24:00 must stay at end-of-day, not wrap to
      // 00:00 (start of the day, in the past).
      expect(snapMinuteOfDay(24 * 60, 15), 24 * 60);
      expect(snapMinuteOfDay(24 * 60 - 1, 15), 24 * 60);
      expect(snapMinuteOfDay(-15, 15), 0);
    });
  });

  group('persistence', () {
    test('round-trips', () {
      final index = learnEffortIndex([
        worked(id: 'a', minutes: 30, startedAt: DateTime(2026, 10, 1, 18)),
        worked(id: 'b', minutes: 45, startedAt: DateTime(2026, 10, 2, 18)),
      ]);
      final json = index.single.toJson();
      final back = AssignmentTypeEffort.fromJson(json);
      expect(back.groupKey, index.single.groupKey);
      expect(back.minutes, index.single.minutes);
      expect(back.startMinutes, index.single.startMinutes);
      expect(back.estimateMinutes, index.single.estimateMinutes);
      expect(back.preferredStartMinute, index.single.preferredStartMinute);
    });

    test('a payload missing every new key loads as an empty row', () {
      final effort = AssignmentTypeEffort.fromJson(const {
        'feedId': 'math290',
        'templateKey': 'video quiz',
      });
      expect(effort.samples, 0);
      expect(effort.estimateMinutes, isNull);
      expect(effort.preferredStartMinute, isNull);
    });

    test('a payload with nonsense values is clamped, not fatal', () {
      final effort = AssignmentTypeEffort.fromJson(const {
        'feedId': 'math290',
        'templateKey': 'video quiz',
        'samples': -5,
        'totalMinutes': -1,
        'minutes': [30, -9, 'x', 1e9],
        'startMinutes': [70, 2880, null],
      });
      expect(effort.samples, 0);
      expect(effort.totalMinutes, 0);
      expect(effort.minutes, [30]);
      expect(effort.startMinutes, [70]);
    });

    test('a payload without feed/template keys rejects the row', () {
      expect(
        () => AssignmentTypeEffort.fromJson(const {'feedId': 'x'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => AssignmentTypeEffort.fromJson(const {'templateKey': 'x'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('an old rule payload without estimateMinutes still loads', () {
      final rule = AssignmentRule.fromJson(const {
        'id': 'r1',
        'feedId': 'math290',
        'templateKey': 'video quiz',
        'displayName': 'Video Quiz',
        'dueOffsetDays': -2,
        'createdAt': '2026-10-01T00:00:00.000',
      });
      expect(rule.estimateMinutes, isNull);
      expect(rule.dueOffsetDays, -2);
    });

    test('a nonsense estimate is clamped and round-trips', () {
      final rule = AssignmentRule.fromJson(const {
        'id': 'r1',
        'feedId': 'math290',
        'templateKey': 'video quiz',
        'displayName': 'Video Quiz',
        'dueOffsetDays': 0,
        'estimateMinutes': 100000,
        'createdAt': '2026-10-01T00:00:00.000',
      });
      expect(rule.estimateMinutes, 1440);
      final zero = AssignmentRule.fromJson({
        ...rule.toJson(),
        'estimateMinutes': 0,
      });
      expect(zero.estimateMinutes, isNull);
    });
  });
}
