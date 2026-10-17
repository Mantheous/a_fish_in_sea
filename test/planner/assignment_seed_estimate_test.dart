import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/model/assignment_estimate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('draftSeedFromNode fills the expected span', () {
    test('uses the estimate for the duration, not a fixed hour', () {
      final seed = draftSeedFromNode(
        Node(
          id: 'n1',
          title: 'Video Quiz 3.1',
          createdAt: DateTime(2026),
          feedId: 'math290',
          schedule: ScheduleFacet(due: DateTime(2026, 10, 16, 23)),
        ),
        estimate: const AssignmentEstimate(
          minutes: 45,
          source: AssignmentEstimateSource.learned,
        ),
      );
      expect(seed.start, DateTime(2026, 10, 16, 9));
      expect(seed.end, DateTime(2026, 10, 16, 9, 45));
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
      expect(seed.start, DateTime(2026, 10, 16, 9));
      expect(seed.end, DateTime(2026, 10, 16, 10));
    });

    test('starts at the habitual hour the user actually starts', () {
      final seed = draftSeedFromNode(
        Node(
          id: 'n1',
          title: 'Video Quiz 3.1',
          createdAt: DateTime(2026),
          feedId: 'math290',
          schedule: ScheduleFacet(due: DateTime(2026, 10, 16, 23)),
        ),
        estimate: const AssignmentEstimate(
          minutes: 30,
          source: AssignmentEstimateSource.learned,
          preferredStartMinute: 19 * 60, // 7 PM
        ),
      );
      expect(seed.start, DateTime(2026, 10, 16, 19));
      expect(seed.end, DateTime(2026, 10, 16, 19, 30));
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
        estimate: const AssignmentEstimate(
          minutes: 45,
          source: AssignmentEstimateSource.learned,
          preferredStartMinute: 19 * 60 + 7,
        ),
        snapMinutes: 30,
      );
      expect(seed.start, DateTime(2026, 10, 16, 19));
      // The end rounds UP to the next grid slot: a 45-minute estimate on a
      // 30-minute grid becomes a 60-minute block, never a truncated 30.
      expect(seed.end, DateTime(2026, 10, 16, 20));
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
        estimate: const AssignmentEstimate(
          minutes: 30,
          source: AssignmentEstimateSource.learned,
        ),
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
        estimate: const AssignmentEstimate(
          minutes: 30,
          source: AssignmentEstimateSource.learned,
          preferredStartMinute: 7 * 60, // 7 AM, long gone
        ),
      );
      expect(seed.start.isBefore(now), isFalse);
      expect(seed.start, DateTime(2026, 10, 16, 21));
      expect(seed.end, DateTime(2026, 10, 16, 21, 30));
    });

    test('pulls a late-night habit back onto the due day', () {
      final seed = draftSeedFromNode(
        Node(
          id: 'n1',
          title: 'Video Quiz',
          createdAt: DateTime(2026),
          feedId: 'math290',
          schedule: ScheduleFacet(due: DateTime(2026, 10, 16, 23)),
        ),
        estimate: const AssignmentEstimate(
          minutes: 90,
          source: AssignmentEstimateSource.learned,
          preferredStartMinute: 23 * 60 + 30, // 11:30 PM
        ),
      );
      expect(seed.start.day, 16);
      expect(seed.end.day, 16);
      expect(seed.start.hour, lessThan(23));
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
        estimate: const AssignmentEstimate(
          minutes: 45,
          source: AssignmentEstimateSource.learned,
        ),
      );
      expect(seed.id, calendarDraftEventId);
      expect(seed.taskId, 'n1');
      expect(seed.start, DateTime(2026, 10, 16, 9));
      expect(seed.end, DateTime(2026, 10, 16, 9, 45));
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
        estimate: const AssignmentEstimate(
          minutes: 30,
          source: AssignmentEstimateSource.learned,
        ),
      );
      expect(seed.start.isBefore(now), isFalse);
      expect(seed.start, DateTime(2026, 10, 16, 9));
      expect(seed.end, DateTime(2026, 10, 16, 9, 30));
    });
  });
}
