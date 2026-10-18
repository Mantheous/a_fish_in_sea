import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NodeRecurrence persistence', () {
    test('round-trips custom period and month day', () {
      const recurrence = NodeRecurrence(
        frequency: TimeScale.custom,
        customPeriodDays: 17,
        dayOfMonth: 31,
      );

      expect(NodeRecurrence.fromJson(recurrence.toJson()), recurrence);
    });

    test('normalizes invalid custom period to one day', () {
      final json = const NodeRecurrence(
        frequency: TimeScale.custom,
        customPeriodDays: 1,
      ).toJson()..['customPeriodDays'] = 0;

      expect(NodeRecurrence.fromJson(json).customPeriodDays, 1);
    });
  });
}
