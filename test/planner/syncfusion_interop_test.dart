import 'package:a_fish_in_sea/planner/model/recurrence.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

void main() {
  group('Syncfusion interop', () {
    test('weekly MWF rule expands to expected occurrences', () {
      const config = RepeatConfig(
        kind: RepeatKind.weekly,
        weekDays: {1, 3, 5},
      );
      final rule = config.ruleFor(DateTime(2026, 9, 2));
      final occurrences = SfCalendar.getRecurrenceDateTimeCollection(
        rule,
        DateTime(2026, 9, 2, 10),
        specificStartDate: DateTime(2026, 9, 2),
        specificEndDate: DateTime(2026, 9, 12),
      );
      final dates = occurrences
          .map((d) => DateTime(d.year, d.month, d.day))
          .toSet();
      expect(dates, {
        DateTime(2026, 9, 2),
        DateTime(2026, 9, 4),
        DateTime(2026, 9, 7),
        DateTime(2026, 9, 9),
        DateTime(2026, 9, 11),
      });
    });

    test('biweekly rule skips the off week', () {
      const config = RepeatConfig(
        kind: RepeatKind.biweekly,
        weekDays: {2},
      );
      final rule = config.ruleFor(DateTime(2026, 9, 1));
      final occurrences = SfCalendar.getRecurrenceDateTimeCollection(
        rule,
        DateTime(2026, 9, 1, 10),
        specificStartDate: DateTime(2026, 9, 1),
        specificEndDate: DateTime(2026, 10, 1),
      );
      final dates = occurrences
          .map((d) => DateTime(d.year, d.month, d.day))
          .toSet();
      expect(dates, {
        DateTime(2026, 9, 1),
        DateTime(2026, 9, 15),
        DateTime(2026, 9, 29),
      });
    });

    test('COUNT bounds the occurrences', () {
      const config = RepeatConfig(
        kind: RepeatKind.daily,
        endKind: RepeatEndKind.after,
        count: 3,
      );
      final rule = config.ruleFor(DateTime(2026, 9, 1));
      final occurrences = SfCalendar.getRecurrenceDateTimeCollection(
        rule,
        DateTime(2026, 9, 1, 9),
        specificStartDate: DateTime(2026, 9, 1),
        specificEndDate: DateTime(2026, 9, 30),
      );
      expect(occurrences.length, 3);
    });

    test('UNTIL bounds the occurrences', () {
      final config = RepeatConfig(
        kind: RepeatKind.daily,
        endKind: RepeatEndKind.until,
        until: DateTime(2026, 9, 5),
      );
      final rule = config.ruleFor(DateTime(2026, 9, 1));
      final occurrences = SfCalendar.getRecurrenceDateTimeCollection(
        rule,
        DateTime(2026, 9, 1, 9),
        specificStartDate: DateTime(2026, 9, 1),
        specificEndDate: DateTime(2026, 9, 30),
      );
      final dates = occurrences
          .map((d) => DateTime(d.year, d.month, d.day))
          .toSet();
      expect(dates.length, 5);
      expect(dates.contains(DateTime(2026, 9, 5)), isTrue);
      expect(dates.contains(DateTime(2026, 9, 6)), isFalse);
    });

    test('weekday rule expands Monday to Friday', () {
      const config = RepeatConfig(kind: RepeatKind.weekdays);
      final rule = config.ruleFor(DateTime(2026, 9, 2));
      final occurrences = SfCalendar.getRecurrenceDateTimeCollection(
        rule,
        DateTime(2026, 9, 2, 9),
        specificStartDate: DateTime(2026, 9, 4),
        specificEndDate: DateTime(2026, 9, 7),
      );
      final dates = occurrences
          .map((d) => DateTime(d.year, d.month, d.day))
          .toSet();
      expect(dates, {
        DateTime(2026, 9, 4),
        DateTime(2026, 9, 7),
      });
    });
  });
}
