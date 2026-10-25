import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_calendar.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 18, 12);

  Node node(
    String id, {
    ScheduleFacet? schedule,
    String? calendarEventId,
    String? sourceEventId,
  }) =>
      Node(
        id: id,
        title: id,
        createdAt: DateTime(2026),
        schedule: schedule,
        calendarEventId: calendarEventId,
        sourceEventId: sourceEventId,
      );

  PlannerEvent event(
    String id, {
    required DateTime start,
    Duration length = const Duration(hours: 1),
    String? taskId,
    bool allDay = false,
  }) =>
      PlannerEvent(
        id: id,
        subject: id,
        start: start,
        end: start.add(length),
        taskId: taskId,
        isTask: taskId != null,
        allDay: allDay,
      );

  group('futureCalendarEntryCounts', () {
    test('empty node list yields an empty map', () {
      expect(futureCalendarEntryCounts(const [], const [], now), isEmpty);
    });

    test('counts a future timed event linked through the task id', () {
      final counts = futureCalendarEntryCounts(
        [node('n1'), node('n2')],
        [event('e1', start: now.add(const Duration(days: 1)), taskId: 'n1')],
        now,
      );
      expect(counts, {'n1': 1});
    });

    test('one event reached through both link shapes counts once', () {
      final counts = futureCalendarEntryCounts(
        [node('n1', calendarEventId: 'e1')],
        [event('e1', start: now.add(const Duration(days: 1)), taskId: 'n1')],
        now,
      );
      expect(counts, {'n1': 1});
    });

    test('ignores all-day events and past events', () {
      final counts = futureCalendarEntryCounts(
        [node('n1')],
        [
          event(
            'e1',
            start: now.add(const Duration(days: 1)),
            taskId: 'n1',
            allDay: true,
          ),
          event(
            'e2',
            start: now.subtract(const Duration(days: 1)),
            taskId: 'n1',
          ),
        ],
        now,
      );
      expect(counts, isEmpty);
    });

    test('counts multiple future timed events for one task', () {
      final counts = futureCalendarEntryCounts(
        [node('n1')],
        [
          event('e1', start: now.add(const Duration(days: 1)), taskId: 'n1'),
          event('e2', start: now.add(const Duration(days: 2)), taskId: 'n1'),
          event('e3', start: now.add(const Duration(days: 3)), taskId: 'n1',
              allDay: true),
        ],
        now,
      );
      expect(counts, {'n1': 2});
    });

    test('counts a source-linked feed event, not the mirrored block', () {
      final counts = futureCalendarEntryCounts(
        [
          node(
            'n1',
            sourceEventId: 'e1',
            // The calendar renders the real event, not this block.
            schedule: ScheduleFacet(
              start: now.add(const Duration(days: 1)),
              end: now.add(const Duration(days: 1, hours: 1)),
            ),
          ),
        ],
        [event('e1', start: now.add(const Duration(days: 1)))],
        now,
      );
      expect(counts, {'n1': 1});
    });

    test('counts an unlinked future timed schedule block as the own entry',
        () {
      final counts = futureCalendarEntryCounts(
        [
          node(
            'n1',
            schedule: ScheduleFacet(
              start: now.add(const Duration(hours: 3)),
              end: now.add(const Duration(hours: 4)),
            ),
          ),
        ],
        const [],
        now,
      );
      expect(counts, {'n1': 1});
    });

    test('ignores all-day and past schedule blocks', () {
      final counts = futureCalendarEntryCounts(
        [
          node(
            'n1',
            schedule: ScheduleFacet(
              start: now.add(const Duration(hours: 3)),
              end: now.add(const Duration(hours: 4)),
              allDay: true,
            ),
          ),
          node(
            'n2',
            schedule: ScheduleFacet(
              start: now.subtract(const Duration(hours: 3)),
              end: now.subtract(const Duration(hours: 2)),
            ),
          ),
        ],
        const [],
        now,
      );
      expect(counts, isEmpty);
    });

    test('combines linked events and the own block into one count', () {
      final counts = futureCalendarEntryCounts(
        [
          node(
            'n1',
            schedule: ScheduleFacet(
              start: now.add(const Duration(hours: 3)),
              end: now.add(const Duration(hours: 4)),
            ),
          ),
        ],
        [event('e1', start: now.add(const Duration(days: 1)), taskId: 'n1')],
        now,
      );
      expect(counts, {'n1': 2});
    });
  });

  group('upcomingNodePlans', () {
    test('carries the earliest upcoming slot', () {
      final plans = upcomingNodePlans(
        [node('n1')],
        [
          event(
            'e1',
            start: now.add(const Duration(days: 2)),
            length: const Duration(minutes: 90),
            taskId: 'n1',
          ),
          event('e2', start: now.add(const Duration(days: 1)), taskId: 'n1'),
        ],
        now,
      );
      expect(plans.counts, {'n1': 2});
      expect(
        plans.nextSlots['n1'],
        PlannedSlot(
          start: now.add(const Duration(days: 1)),
          end: now.add(const Duration(days: 1, hours: 1)),
        ),
      );
    });

    test('all-day and past entries add no slot', () {
      final plans = upcomingNodePlans(
        [node('n1')],
        [
          event(
            'e1',
            start: now.add(const Duration(days: 1)),
            taskId: 'n1',
            allDay: true,
          ),
          event(
            'e2',
            start: now.subtract(const Duration(days: 1)),
            taskId: 'n1',
          ),
        ],
        now,
      );
      expect(plans.counts, isEmpty);
      expect(plans.nextSlots, isEmpty);
    });

    test('source-linked event is the slot, not the mirrored block', () {
      final blockStart = now.add(const Duration(hours: 2));
      final plans = upcomingNodePlans(
        [
          node(
            'n1',
            sourceEventId: 'e1',
            schedule: ScheduleFacet(
              start: blockStart,
              end: blockStart.add(const Duration(minutes: 45)),
            ),
          ),
        ],
        [event('e1', start: blockStart)],
        now,
      );
      expect(plans.counts, {'n1': 1});
      expect(
        plans.nextSlots['n1'],
        PlannedSlot(
          start: blockStart,
          end: blockStart.add(const Duration(hours: 1)),
        ),
      );
    });
  });
}
