import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/model/assignment_estimate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Learned estimate with [samples] recorded sessions behind it. The seed
  /// trusts these for sizing only once enough sessions exist.
  AssignmentEstimate learned(
    int minutes, {
    int samples = 3,
    int? preferredStartMinute,
  }) =>
      AssignmentEstimate(
        minutes: minutes,
        source: AssignmentEstimateSource.learned,
        preferredStartMinute: preferredStartMinute,
        effort: AssignmentTypeEffort(
          feedId: 'math290',
          templateKey: 'video quiz',
          samples: samples,
          totalMinutes: minutes * samples,
          minutes: [for (var i = 0; i < samples; i++) minutes],
          startMinutes: preferredStartMinute == null
              ? const []
              : [preferredStartMinute],
          minMinutes: minutes,
          maxMinutes: minutes,
          updatedAt: DateTime(2026),
        ),
      );

  group('draftSeedFromNode fills the expected span', () {
    test('starts at noon and uses a learned estimate once enough sessions '
        'back it', () {
      final seed = draftSeedFromNode(
        Node(
          id: 'n1',
          title: 'Video Quiz 3.1',
          createdAt: DateTime(2026),
          feedId: 'math290',
          schedule: ScheduleFacet(due: DateTime(2026, 10, 16, 23)),
        ),
        estimate: learned(45),
      );
      expect(seed.start, DateTime(2026, 10, 16, 12));
      expect(seed.end, DateTime(2026, 10, 16, 12, 45));
    });

    test('one or two sessions are not enough to size the block', () {
      final seed = draftSeedFromNode(
        Node(
          id: 'n1',
          title: 'Video Quiz 3.1',
          createdAt: DateTime(2026),
          feedId: 'math290',
          schedule: ScheduleFacet(due: DateTime(2026, 10, 16, 23)),
        ),
        estimate: learned(45, samples: 2),
      );
      expect(seed.start, DateTime(2026, 10, 16, 12));
      expect(seed.end, DateTime(2026, 10, 16, 13));
    });

    test('a rule estimate is trusted like any explicit number', () {
      final seed = draftSeedFromNode(
        Node(
          id: 'n1',
          title: 'Problem Set 5',
          createdAt: DateTime(2026),
          feedId: 'math290',
          schedule: ScheduleFacet(due: DateTime(2026, 10, 16, 23)),
        ),
        estimate: const AssignmentEstimate(
          minutes: 90,
          source: AssignmentEstimateSource.rule,
        ),
      );
      expect(seed.start, DateTime(2026, 10, 16, 12));
      expect(seed.end, DateTime(2026, 10, 16, 13, 30));
    });

    test('defaults to an hour when nothing is known', () {
      final seed = draftSeedFromNode(
        Node(
          id: 'n1',
          title: 'Something',
          createdAt: DateTime(2026),
          schedule: ScheduleFacet(due: DateTime(2026, 10, 16, 23)),
        ),
      );
      expect(seed.start, DateTime(2026, 10, 16, 12));
      expect(seed.end, DateTime(2026, 10, 16, 13));
    });

    test('ignores the learned habitual hour for now: placement prediction '
        'is left to a later feature', () {
      final seed = draftSeedFromNode(
        Node(
          id: 'n1',
          title: 'Video Quiz 3.1',
          createdAt: DateTime(2026),
          feedId: 'math290',
          schedule: ScheduleFacet(due: DateTime(2026, 10, 16, 23)),
        ),
        estimate: learned(30, preferredStartMinute: 19 * 60), // 7 PM habit
      );
      expect(seed.start, DateTime(2026, 10, 16, 12));
      expect(seed.end, DateTime(2026, 10, 16, 12, 30));
    });

    test('snaps both ends to the calendar setting', () {
      final seed = draftSeedFromNode(
        Node(
          id: 'n1',
          title: 'Video Quiz',
          createdAt: DateTime(2026),
          feedId: 'math290',
          schedule: ScheduleFacet(due: DateTime(2026, 10, 16, 23)),
        ),
        estimate: learned(45),
        snapMinutes: 30,
      );
      expect(seed.start, DateTime(2026, 10, 16, 12));
      // The end rounds UP to the next grid slot: a 45-minute estimate on a
      // 30-minute grid becomes a 60-minute block, never a truncated 30.
      expect(seed.end, DateTime(2026, 10, 16, 13));
    });

    test('keeps an existing block instead of re-seeding it', () {
      final start = DateTime(2026, 10, 16, 7, 30);
      final seed = draftSeedFromNode(
        Node(
          id: 'n1',
          title: 'Video Quiz',
          createdAt: DateTime(2026),
          feedId: 'math290',
          schedule: ScheduleFacet(
            due: DateTime(2026, 10, 18, 23),
            start: start,
            end: start.add(const Duration(hours: 2)),
          ),
        ),
        estimate: learned(30),
      );
      expect(seed.start, start);
      expect(seed.end, start.add(const Duration(hours: 2)));
    });

    test('never seeds a block in the past', () {
      final now = DateTime(2026, 10, 16, 21, 0);
      final seed = draftSeedFromNode(
        Node(
          id: 'n1',
          title: 'Video Quiz',
          createdAt: DateTime(2026),
          feedId: 'math290',
          schedule: ScheduleFacet(due: DateTime(2026, 10, 16, 23)),
        ),
        now: now,
        estimate: learned(30),
      );
      expect(seed.start.isBefore(now), isFalse);
      expect(seed.start, DateTime(2026, 10, 16, 21));
      expect(seed.end, DateTime(2026, 10, 16, 21, 30));
    });

    test('pulls a very long block back onto the due day', () {
      final seed = draftSeedFromNode(
        Node(
          id: 'n1',
          title: 'Marathon project',
          createdAt: DateTime(2026),
          feedId: 'math290',
          schedule: ScheduleFacet(due: DateTime(2026, 10, 16, 23)),
        ),
        estimate: const AssignmentEstimate(
          minutes: 14 * 60,
          source: AssignmentEstimateSource.rule,
        ),
      );
      expect(seed.start.day, 16);
      expect(seed.end.day, 16);
      expect(seed.end.isAfter(seed.start), isTrue);
    });
  });

  group('imported assignment windows are not planned work', () {
    test('a zero-length window seeds fresh at noon', () {
      final seed = draftSeedFromNode(
        Node(
          id: 'n1',
          title: 'Reading Quiz Section 2',
          createdAt: DateTime(2026),
          feedId: 'math290',
          schedule: ScheduleFacet(
            due: DateTime(2026, 10, 16, 17),
            start: DateTime(2026, 10, 16, 17),
            end: DateTime(2026, 10, 16, 17),
          ),
        ),
      );
      expect(seed.start, DateTime(2026, 10, 16, 12));
      expect(seed.end, DateTime(2026, 10, 16, 13));
    });

    test('a multi-day window seeds fresh at noon on the due day', () {
      final seed = draftSeedFromNode(
        Node(
          id: 'n1',
          title: 'Homework 5',
          createdAt: DateTime(2026),
          feedId: 'math290',
          schedule: ScheduleFacet(
            due: DateTime(2026, 10, 16),
            start: DateTime(2026, 10, 2),
            end: DateTime(2026, 10, 16),
          ),
        ),
      );
      expect(seed.start, DateTime(2026, 10, 16, 12));
      expect(seed.end, DateTime(2026, 10, 16, 13));
    });
  });

  group('draftSeedForFollowUp', () {
    test('shifts the current block one day forward, keeping time and length',
        () {
      final start = DateTime(2026, 10, 16, 14);
      final seed = draftSeedForFollowUp(
        Node(
          id: 'n1',
          title: 'Video Quiz',
          createdAt: DateTime(2026),
          feedId: 'math290',
          schedule: ScheduleFacet(
            due: DateTime(2026, 10, 18, 23),
            start: start,
            end: start.add(const Duration(hours: 2)),
          ),
        ),
        now: DateTime(2026, 10, 16, 9),
      );
      expect(seed.id, calendarDraftEventId);
      expect(seed.taskId, 'n1');
      expect(seed.subject, 'Video Quiz');
      expect(seed.start, DateTime(2026, 10, 17, 14));
      expect(seed.end, DateTime(2026, 10, 17, 16));
    });

    test('falls back to the estimate flow when there is no block', () {
      final seed = draftSeedForFollowUp(
        Node(
          id: 'n1',
          title: 'Video Quiz 3.1',
          createdAt: DateTime(2026),
          feedId: 'math290',
          schedule: ScheduleFacet(due: DateTime(2026, 10, 16, 23)),
        ),
        now: DateTime(2026, 10, 16, 8),
        estimate: learned(45),
      );
      expect(seed.id, calendarDraftEventId);
      expect(seed.taskId, 'n1');
      expect(seed.start, DateTime(2026, 10, 16, 12));
      expect(seed.end, DateTime(2026, 10, 16, 12, 45));
    });

    test('a stale block falls back to a future estimate slot', () {
      final now = DateTime(2026, 10, 16, 8);
      final seed = draftSeedForFollowUp(
        Node(
          id: 'n1',
          title: 'Old work',
          createdAt: DateTime(2026),
          schedule: ScheduleFacet(
            start: DateTime(2026, 9, 1, 14),
            end: DateTime(2026, 9, 1, 15),
          ),
        ),
        now: now,
        estimate: learned(30),
      );
      expect(seed.start.isBefore(now), isFalse);
      expect(seed.start, DateTime(2026, 10, 16, 12));
      expect(seed.end, DateTime(2026, 10, 16, 12, 30));
    });

    test('an overdue due date still seeds a future follow-up', () {
      final now = DateTime(2026, 10, 16, 8);
      final seed = draftSeedForFollowUp(
        Node(
          id: 'n1',
          title: 'Overdue quiz',
          createdAt: DateTime(2026),
          schedule: ScheduleFacet(due: DateTime(2026, 10, 11, 23)),
        ),
        now: now,
        estimate: learned(30),
      );
      expect(seed.start.isBefore(now), isFalse);
      expect(seed.start, DateTime(2026, 10, 16, 12));
      expect(seed.end, DateTime(2026, 10, 16, 12, 30));
    });

    test('an overdue due date after noon rolls to tomorrow', () {
      final now = DateTime(2026, 10, 16, 15);
      final seed = draftSeedForFollowUp(
        Node(
          id: 'n1',
          title: 'Overdue quiz',
          createdAt: DateTime(2026),
          schedule: ScheduleFacet(due: DateTime(2026, 10, 11, 23)),
        ),
        now: now,
        estimate: learned(30),
      );
      expect(seed.start, DateTime(2026, 10, 17, 12));
      expect(seed.end, DateTime(2026, 10, 17, 12, 30));
    });

    test('a zero-length block is not carried forward', () {
      final seed = draftSeedForFollowUp(
        Node(
          id: 'n1',
          title: 'Reading Quiz',
          createdAt: DateTime(2026),
          schedule: ScheduleFacet(
            start: DateTime(2026, 10, 17, 17),
            end: DateTime(2026, 10, 17, 17),
          ),
        ),
        now: DateTime(2026, 10, 16, 8),
      );
      expect(seed.start, DateTime(2026, 10, 17, 12));
      expect(seed.end, DateTime(2026, 10, 17, 13));
    });
  });
}
