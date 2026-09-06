import 'package:a_fish_in_sea/planner/model/ical_recurrence.dart';
import 'package:a_fish_in_sea/planner/model/recurrence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RepeatConfig.ruleFor', () {
    test('none produces empty rule', () {
      const config = RepeatConfig();
      expect(config.ruleFor(DateTime(2026, 9, 4)), '');
    });

    test('daily', () {
      const config = RepeatConfig(kind: RepeatKind.daily);
      expect(config.ruleFor(DateTime(2026, 9, 4)), 'FREQ=DAILY');
    });

    test('weekdays', () {
      const config = RepeatConfig(kind: RepeatKind.weekdays);
      expect(
        config.ruleFor(DateTime(2026, 9, 4)),
        'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
      );
    });

    test('weekly with multiple days', () {
      const config = RepeatConfig(
        kind: RepeatKind.weekly,
        weekDays: {1, 3, 5},
      );
      expect(
        config.ruleFor(DateTime(2026, 9, 4)),
        'FREQ=WEEKLY;BYDAY=MO,WE,FR',
      );
    });

    test('biweekly', () {
      const config = RepeatConfig(
        kind: RepeatKind.biweekly,
        weekDays: {2},
      );
      expect(
        config.ruleFor(DateTime(2026, 9, 4)),
        'FREQ=WEEKLY;INTERVAL=2;BYDAY=TU',
      );
    });

    test('monthly uses day of month from start', () {
      const config = RepeatConfig(kind: RepeatKind.monthly);
      expect(
        config.ruleFor(DateTime(2026, 9, 15)),
        'FREQ=MONTHLY;BYMONTHDAY=15',
      );
    });

    test('yearly uses month and day from start', () {
      const config = RepeatConfig(kind: RepeatKind.yearly);
      expect(
        config.ruleFor(DateTime(2026, 1, 5)),
        'FREQ=YEARLY;BYMONTH=1;BYMONTHDAY=5',
      );
    });

    test('count end', () {
      const config = RepeatConfig(
        kind: RepeatKind.daily,
        endKind: RepeatEndKind.after,
        count: 3,
      );
      expect(config.ruleFor(DateTime(2026, 9, 4)), 'FREQ=DAILY;COUNT=3');
    });

    test('until end', () {
      final config = RepeatConfig(
        kind: RepeatKind.daily,
        endKind: RepeatEndKind.until,
        until: DateTime(2026, 10, 31),
      );
      expect(
        config.ruleFor(DateTime(2026, 9, 4)),
        'FREQ=DAILY;UNTIL=20261031T235900Z',
      );
    });
  });

  group('RepeatConfig.tryParse', () {
    test('round trips daily', () {
      final parsed = RepeatConfig.tryParse('FREQ=DAILY');
      expect(parsed?.kind, RepeatKind.daily);
      expect(parsed?.endKind, RepeatEndKind.never);
    });

    test('round trips weekly multi-day', () {
      final parsed = RepeatConfig.tryParse('FREQ=WEEKLY;BYDAY=MO,WE,FR');
      expect(parsed?.kind, RepeatKind.weekly);
      expect(parsed?.weekDays, {1, 3, 5});
    });

    test('round trips weekdays', () {
      final parsed =
          RepeatConfig.tryParse('FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR');
      expect(parsed?.kind, RepeatKind.weekdays);
    });

    test('round trips biweekly', () {
      final parsed =
          RepeatConfig.tryParse('FREQ=WEEKLY;INTERVAL=2;BYDAY=TU');
      expect(parsed?.kind, RepeatKind.biweekly);
      expect(parsed?.weekDays, {2});
    });

    test('round trips monthly', () {
      final parsed = RepeatConfig.tryParse('FREQ=MONTHLY;BYMONTHDAY=15');
      expect(parsed?.kind, RepeatKind.monthly);
    });

    test('round trips yearly', () {
      final parsed =
          RepeatConfig.tryParse('FREQ=YEARLY;BYMONTH=1;BYMONTHDAY=5');
      expect(parsed?.kind, RepeatKind.yearly);
    });

    test('round trips count', () {
      final parsed = RepeatConfig.tryParse('FREQ=DAILY;COUNT=7');
      expect(parsed?.endKind, RepeatEndKind.after);
      expect(parsed?.count, 7);
    });

    test('round trips until', () {
      final parsed =
          RepeatConfig.tryParse('FREQ=DAILY;UNTIL=20261031T235900Z');
      expect(parsed?.endKind, RepeatEndKind.until);
      expect(
        parsed?.until?.toUtc(),
        DateTime.utc(2026, 10, 31, 23, 59),
      );
    });

    test('rejects unsupported rules', () {
      expect(RepeatConfig.tryParse('FREQ=HOURLY;INTERVAL=3'), isNull);
      expect(RepeatConfig.tryParse('FREQ=DAILY;INTERVAL=5'), isNull);
      expect(RepeatConfig.tryParse('garbage'), isNull);
    });

    test('rule round trip preserves meaning', () {
      const config = RepeatConfig(
        kind: RepeatKind.weekly,
        weekDays: {2, 4},
        endKind: RepeatEndKind.after,
        count: 10,
      );
      final parsed = RepeatConfig.tryParse(config.ruleFor(DateTime(2026, 9, 4)));
      expect(parsed, config);
    });
  });

  group('repeatConfigFromICal', () {
    test('maps daily', () {
      final config = repeatConfigFromICal(
        const ICalRecurrence(frequency: ICalFrequency.daily),
        DateTime(2026, 9, 4),
      );
      expect(config?.kind, RepeatKind.daily);
    });

    test('maps weekly with by days', () {
      final config = repeatConfigFromICal(
        const ICalRecurrence(
          frequency: ICalFrequency.weekly,
          byWeekDay: [ICalByDay(1), ICalByDay(3)],
        ),
        DateTime(2026, 9, 4),
      );
      expect(config?.kind, RepeatKind.weekly);
      expect(config?.weekDays, {1, 3});
    });

    test('rejects weekly with ordinal week numbers', () {
      final config = repeatConfigFromICal(
        const ICalRecurrence(
          frequency: ICalFrequency.monthly,
          byWeekDay: [ICalByDay(1, week: 2)],
        ),
        DateTime(2026, 9, 4),
      );
      expect(config, isNull);
    });

    test('rejects bySetPos rules', () {
      final config = repeatConfigFromICal(
        const ICalRecurrence(
          frequency: ICalFrequency.monthly,
          bySetPos: [1],
        ),
        DateTime(2026, 9, 4),
      );
      expect(config, isNull);
    });

    test('maps biweekly', () {
      final config = repeatConfigFromICal(
        const ICalRecurrence(
          frequency: ICalFrequency.weekly,
          interval: 2,
          byWeekDay: [ICalByDay(4)],
        ),
        DateTime(2026, 9, 4),
      );
      expect(config?.kind, RepeatKind.biweekly);
    });

    test('passes count through', () {
      final config = repeatConfigFromICal(
        const ICalRecurrence(
          frequency: ICalFrequency.daily,
          count: 5,
        ),
        DateTime(2026, 9, 4),
      );
      expect(config?.endKind, RepeatEndKind.after);
      expect(config?.count, 5);
    });
  });
}
