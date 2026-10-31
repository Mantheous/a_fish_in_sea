import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/auto_goal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('windows', () {
    test('weekly starts Monday and daily is local midnight', () {
      final weekly = autoGoalWindow(
        const AutoFacet(),
        DateTime(2026, 10, 14, 16),
      );
      expect(weekly.start, DateTime(2026, 10, 12));
      expect(weekly.end, DateTime(2026, 10, 19));

      final daily = autoGoalWindow(
        const AutoFacet(period: TimeScale.daily),
        DateTime(2026, 10, 14, 16),
      );
      expect(daily.start, DateTime(2026, 10, 14));
      expect(daily.end, DateTime(2026, 10, 15));
    });

    test('custom periods are anchored to the goal, not the calendar', () {
      final facet = const AutoFacet(
        period: TimeScale.custom,
        customPeriodDays: 10,
      );
      final first = autoGoalWindow(
        facet,
        DateTime(2026, 10, 14),
        anchor: DateTime(2026, 10, 1),
      );
      final next = autoGoalWindow(
        facet,
        DateTime(2026, 10, 22),
        anchor: DateTime(2026, 10, 1),
      );
      expect(first.start, DateTime(2026, 10, 11));
      expect(next.start, DateTime(2026, 10, 21));
    });
  });
}
