import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_recurrence_schedule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NodeRecurrenceSchedule', () {
    test('yearly occurrences keep the template anchor phase', () {
      const recurrence = NodeRecurrence(frequency: TimeScale.yearly);
      final first = NodeRecurrenceSchedule.firstOnOrAfter(
        DateTime(2024, 6, 15),
        recurrence,
        DateTime(2026, 8, 1),
      );

      expect(first, DateTime(2027, 6, 15));
      expect(
        NodeRecurrenceSchedule.next(DateTime(2024, 6, 15), first, recurrence),
        DateTime(2028, 6, 15),
      );
    });

    test('biweekly occurrences retain parity from the anchor', () {
      const recurrence = NodeRecurrence(frequency: TimeScale.biweekly);
      final first = NodeRecurrenceSchedule.firstOnOrAfter(
        DateTime(2026, 9, 18),
        recurrence,
        DateTime(2026, 10, 3),
      );

      expect(first, DateTime(2026, 10, 16));
    });

    test('monthly 29th through 31st dates clamp per month and recover', () {
      const recurrence = NodeRecurrence(
        frequency: TimeScale.monthly,
        dayOfMonth: 31,
      );
      var cursor = DateTime(2026, 1, 31);
      final dates = <DateTime>[];
      for (var i = 0; i < 5; i++) {
        dates.add(cursor);
        cursor = NodeRecurrenceSchedule.next(
          DateTime(2026, 1, 31),
          cursor,
          recurrence,
        );
      }

      expect(dates, [
        DateTime(2026, 1, 31),
        DateTime(2026, 2, 28),
        DateTime(2026, 3, 31),
        DateTime(2026, 4, 30),
        DateTime(2026, 5, 31),
      ]);
    });

    test('custom recurrence with a nonpositive period advances safely', () {
      const recurrence = NodeRecurrence(
        frequency: TimeScale.custom,
        customPeriodDays: 0,
      );

      expect(
        NodeRecurrenceSchedule.next(
          DateTime(2026, 1, 1),
          DateTime(2026, 1, 1),
          recurrence,
        ),
        DateTime(2026, 1, 2),
      );
    });

    test('daily calendar stepping keeps consecutive dates around DST', () {
      const recurrence = NodeRecurrence(frequency: TimeScale.daily);
      var cursor = NodeRecurrenceSchedule.firstOnOrAfter(
        DateTime(2026, 3, 7),
        recurrence,
        DateTime(2026, 3, 7),
      );
      final dates = <String>[];
      for (var i = 0; i < 5; i++) {
        dates.add('${cursor.year}-${cursor.month}-${cursor.day}');
        cursor = NodeRecurrenceSchedule.next(
          DateTime(2026, 3, 7),
          cursor,
          recurrence,
        );
      }

      expect(dates, [
        '2026-3-7',
        '2026-3-8',
        '2026-3-9',
        '2026-3-10',
        '2026-3-11',
      ]);
    });
  });
}
