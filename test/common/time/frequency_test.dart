import 'package:a_fish_in_sea/common/time/frequency.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/planner/model/ical_recurrence.dart';
import 'package:a_fish_in_sea/planner/model/recurrence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TimeScale ↔ RepeatKind', () {
    test('scales with a direct planner equivalent round-trip', () {
      for (final scale in const [
        TimeScale.daily,
        TimeScale.weekly,
        TimeScale.biweekly,
        TimeScale.monthly,
        TimeScale.yearly,
      ]) {
        final kind = scale.toRepeatKind();
        expect(kind, isNotNull, reason: '$scale should map to a RepeatKind');
        expect(kind!.toTimeScale(), scale,
            reason: '$scale → $kind → ${kind.toTimeScale()} should round-trip');
        expect(scale.repeatMapping().isExact, isTrue);
      }
    });

    test('weekdays is a lossy, not absent, mapping', () {
      expect(RepeatKind.weekdays.toTimeScale(), TimeScale.weekly);
      final mapping = RepeatKind.weekdays.timeScaleMapping();
      expect(mapping.fidelity, ConversionFidelity.lossy);
      expect(mapping.reason, isNotNull);
    });

    test('quarterly and custom have no RepeatKind and say why', () {
      for (final scale in const [TimeScale.quarterly, TimeScale.custom]) {
        expect(scale.toRepeatKind(), isNull, reason: '$scale has no equivalent');
        final mapping = scale.repeatMapping();
        expect(mapping.fidelity, ConversionFidelity.unsupported);
        expect(mapping.reason, isNotNull);
      }
    });

    test('RepeatKind.none is not a period', () {
      expect(RepeatKind.none.toTimeScale(), isNull);
      expect(RepeatKind.none.timeScaleMapping().fidelity,
          ConversionFidelity.unsupported);
    });

    test('the direction that cannot be expressed never is', () {
      // Approximating quarterly to monthly would silently change a
      // budget's period; asserting it stays null is the point.
      expect(TimeScale.quarterly.toRepeatKind(), isNot(RepeatKind.monthly));
    });
  });

  group('TimeScale → iCalendar', () {
    test('biweekly rides on the interval, not the frequency', () {
      expect(TimeScale.biweekly.toICalFrequency(), ICalFrequency.weekly);
      expect(TimeScale.biweekly.toICalInterval(), 2);
      expect(TimeScale.biweekly.iCalMapping().fidelity, ConversionFidelity.lossy);
    });

    test('every other mappable scale keeps interval 1', () {
      for (final scale in const [
        TimeScale.daily,
        TimeScale.weekly,
        TimeScale.monthly,
        TimeScale.yearly,
      ]) {
        expect(scale.toICalInterval(), 1, reason: '$scale should be every 1');
        expect(scale.iCalMapping().isExact, isTrue);
      }
    });

    test('quarterly and custom have no bare FREQ', () {
      expect(TimeScale.quarterly.toICalFrequency(), isNull);
      expect(TimeScale.custom.toICalFrequency(), isNull);
    });
  });

  group('ICalFrequency → TimeScale', () {
    test('calendar frequencies map to their scale', () {
      expect(ICalFrequency.daily.toTimeScale(), TimeScale.daily);
      expect(ICalFrequency.weekly.toTimeScale(), TimeScale.weekly);
      expect(ICalFrequency.monthly.toTimeScale(), TimeScale.monthly);
      expect(ICalFrequency.yearly.toTimeScale(), TimeScale.yearly);
    });

    test('sub-daily frequencies have no scale in this app', () {
      for (final freq in const [
        ICalFrequency.secondly,
        ICalFrequency.minutely,
        ICalFrequency.hourly,
      ]) {
        expect(freq.toTimeScale(), isNull, reason: '$freq is finer than a day');
        expect(freq.timeScaleMapping().fidelity, ConversionFidelity.unsupported);
      }
    });
  });

  group('FrequencyMapping honesty', () {
    test('every non-exact mapping carries a reason', () {
      final all = <FrequencyMapping>[
        ...TimeScale.values.map((s) => s.repeatMapping()),
        ...TimeScale.values.map((s) => s.iCalMapping()),
        ...RepeatKind.values.map((k) => k.timeScaleMapping()),
        ...ICalFrequency.values.map((f) => f.timeScaleMapping()),
      ];
      for (final mapping in all) {
        if (mapping.isExact) continue;
        expect(mapping.reason, isNotNull,
            reason: 'a ${mapping.fidelity} mapping must explain itself');
      }
    });

    test('no mapping claims lossy when it is actually unsupported', () {
      // Guards against "lossy" becoming a catch-all for "dropped".
      expect(TimeScale.quarterly.repeatMapping().isUnsupported, isTrue);
      expect(TimeScale.custom.iCalMapping().isUnsupported, isTrue);
    });
  });

  group('cross-vocabulary agreement with the live import path', () {
    // repeatConfigFromICal is the real iCal → planner boundary; the
    // vocabulary must agree with what it actually produces.
    test('a weekly iCal rule lands on TimeScale.weekly', () {
      final config = RepeatConfig.tryParse('FREQ=WEEKLY;BYDAY=MO,WE');
      expect(config, isNotNull);
      expect(config!.kind.toTimeScale(), TimeScale.weekly);
    });

    test('a monthly iCal rule lands on TimeScale.monthly', () {
      final config = RepeatConfig.tryParse('FREQ=MONTHLY;BYMONTHDAY=15');
      expect(config!.kind.toTimeScale(), TimeScale.monthly);
    });

    test('RepeatKind.toICalFrequency agrees with the rule it emits', () {
      // A biweekly config emits FREQ=WEEKLY;INTERVAL=2 — the extension has
      // to claim weekly, not biweekly, or the two disagree.
      final config = RepeatConfig(kind: RepeatKind.biweekly);
      expect(config.ruleFor(DateTime(2026, 1, 5)), contains('FREQ=WEEKLY'));
      expect(config.kind.toICalFrequency(), ICalFrequency.weekly);
    });
  });
}
