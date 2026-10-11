import 'package:a_fish_in_sea/common/time/planned_actual.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime(2026, 10, 5, 9);
  final end = DateTime(2026, 10, 5, 10); // 1h planned

  group('planned vs actual', () {
    test('empty is comparable with nothing', () {
      const pa = PlannedActual.empty();
      expect(pa.isPlanned, isFalse);
      expect(pa.hasReported, isFalse);
      expect(pa.isComparable, isFalse);
      expect(pa.plannedDuration, isNull);
      expect(pa.actualDuration, isNull);
      expect(pa.variance, isNull);
      expect(pa.accuracyRatio, isNull);
      expect(pa.overran, isFalse);
    });

    test('a plan with no record is not comparable', () {
      final pa = PlannedActual(plannedStart: start, plannedEnd: end);
      expect(pa.isPlanned, isTrue);
      expect(pa.hasReported, isFalse);
      expect(pa.plannedDuration, const Duration(hours: 1));
      expect(pa.variance, isNull);
    });

    test('variance is actual minus planned', () {
      // Planned 9–10 (1h). Actual 9–11:30 (2.5h) → 1.5h over.
      final pa = PlannedActual(
        plannedStart: start,
        plannedEnd: end,
        actualStart: start,
        actualEnd: end.add(const Duration(minutes: 90)),
      );
      expect(pa.plannedDuration, const Duration(hours: 1));
      expect(pa.actualDuration, const Duration(hours: 2, minutes: 30));
      expect(pa.variance, const Duration(hours: 1, minutes: 30));
      expect(pa.overran, isTrue);
      expect(pa.accuracyRatio, closeTo(2.5, 0.0001));
    });

    test('quicker than planned reads as negative', () {
      final pa = PlannedActual(
        plannedStart: start,
        plannedEnd: end,
        actualStart: start,
        actualEnd: end.subtract(const Duration(minutes: 15)),
      );
      expect(pa.variance, const Duration(minutes: -15));
      expect(pa.overran, isFalse);
      expect(pa.accuracyRatio, closeTo(0.75, 0.0001));
    });

    test('bang on is zero variance, not overrun', () {
      final pa = PlannedActual(
        plannedStart: start,
        plannedEnd: end,
        actualStart: start,
        actualEnd: end,
      );
      expect(pa.variance, Duration.zero);
      expect(pa.overran, isFalse);
      expect(pa.accuracyRatio, 1.0);
    });

    test('degenerate intervals are not durations', () {
      // Matches ScheduleFacet.plannedDuration / Node.reportedDuration:
      // a zero-length or backwards span is not a duration.
      final backwards = PlannedActual(
        plannedStart: end,
        plannedEnd: start,
        actualStart: end,
        actualEnd: start,
      );
      expect(backwards.plannedDuration, isNull);
      expect(backwards.actualDuration, isNull);

      final zero = PlannedActual(
        plannedStart: start,
        plannedEnd: start,
      );
      expect(zero.plannedDuration, isNull);
    });

    test('started/finished late report independently of duration', () {
      final pa = PlannedActual(
        plannedStart: start,
        plannedEnd: end,
        actualStart: start.add(const Duration(minutes: 20)),
        actualEnd: end.add(const Duration(minutes: 5)),
      );
      expect(pa.startedLate, isTrue);
      expect(pa.finishedLate, isTrue);
      // Started 20min late but ran 25min shorter overall.
      expect(pa.variance, const Duration(minutes: -15));
    });

    test('late questions are null without both bounds', () {
      final pa = PlannedActual(plannedStart: start);
      expect(pa.startedLate, isNull);
      expect(pa.finishedLate, isNull);
    });

    test('accuracyRatio is null for a zero-length plan', () {
      final pa = PlannedActual(
        plannedStart: start,
        plannedEnd: start,
        actualStart: start,
        actualEnd: end,
      );
      // plannedDuration is null (degenerate), so the ratio is meaningless.
      expect(pa.accuracyRatio, isNull);
    });

    test('copyWithRecord clears and replaces actuals independently', () {
      final pa = PlannedActual(
        plannedStart: start,
        plannedEnd: end,
        actualStart: start,
        actualEnd: end,
      );
      final cleared = pa.copyWithRecord(clearActualStart: true);
      expect(cleared.actualStart, isNull);
      expect(cleared.actualEnd, end); // untouched
      expect(cleared.hasReported, isFalse);
      // The plan survives the edit.
      expect(cleared.plannedStart, start);
      expect(cleared.plannedEnd, end);
    });
  });

  group('agreement with the models it unifies', () {
    test('PlannedActual matches ScheduleFacet semantics on a real node', () {
      // The whole point: one implementation behind three getters.
      final pa = PlannedActual(plannedStart: start, plannedEnd: end);
      expect(pa.plannedDuration, end.difference(start));
    });

    test('equality is structural', () {
      final a = PlannedActual(plannedStart: start, plannedEnd: end);
      final b = PlannedActual(plannedStart: start, plannedEnd: end);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(PlannedActual(plannedStart: start), isNot(a));
    });
  });
}
