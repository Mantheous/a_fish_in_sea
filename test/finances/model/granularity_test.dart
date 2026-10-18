import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/finances/model/granularity.dart';
import 'package:a_fish_in_sea/finances/model/ledger_entry.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A Wednesday. Oct 7 2026 is a Wednesday.
  final today = DateTime(2026, 10, 7);

  LedgerEntry row(String id, DateTime date, {double amount = -10}) =>
      LedgerEntry(
        sourceId: id,
        name: id,
        amount: amount,
        date: date,
        type: EntryType.expense,
        status: EntryStatus.projected,
      );

  group('GranularityThresholds.resolve', () {
    const t = GranularityThresholds(monthlyThresholdDays: 60, weeklyThresholdDays: 7);

    test('today and the next week bucket daily', () {
      for (final out in const [0, 1, 3, 6, 7]) {
        expect(t.resolve(out), DisplayGranularity.daily,
            reason: '$out days out should still be daily');
      }
    });

    test('the mid range buckets weekly', () {
      for (final out in const [8, 14, 30, 59, 60]) {
        expect(t.resolve(out), DisplayGranularity.weekly,
            reason: '$out days out should be weekly');
      }
    });

    test('past the monthly threshold buckets monthly', () {
      for (final out in const [61, 90, 200, 365]) {
        expect(t.resolve(out), DisplayGranularity.monthly,
            reason: '$out days out should be monthly');
      }
    });

    test('the thresholds are inclusive at both edges', () {
      // weeklyThresholdDays is the last daily day; monthlyThresholdDays is
      // the last weekly day.
      expect(t.resolve(7), DisplayGranularity.daily);
      expect(t.resolve(8), DisplayGranularity.weekly);
      expect(t.resolve(60), DisplayGranularity.weekly);
      expect(t.resolve(61), DisplayGranularity.monthly);
    });

    test('past dates clamp to daily, not monthly', () {
      expect(t.resolve(-400), DisplayGranularity.daily);
      expect(t.resolveFor(today.subtract(const Duration(days: 200)), today),
          DisplayGranularity.daily);
    });

    test('the users thresholds actually change the answer', () {
      // This is the regression the whole file exists for: the values were
      // persisted and editable but never consulted.
      const wide = GranularityThresholds(
          monthlyThresholdDays: 365, weeklyThresholdDays: 30);
      expect(t.resolve(20), DisplayGranularity.weekly);
      expect(wide.resolve(20), DisplayGranularity.daily);
      expect(wide.resolve(100), DisplayGranularity.weekly);
      expect(t.resolve(100), DisplayGranularity.monthly);
    });
  });

  group('bucketStartFor', () {
    test('daily truncates to midnight', () {
      final start = bucketStartFor(DisplayGranularity.daily, today);
      expect(start, DateTime(2026, 10, 7));
    });

    test('weekly starts on Monday', () {
      // Wed Oct 7 → Mon Oct 5.
      final start = bucketStartFor(DisplayGranularity.weekly, today);
      expect(start, DateTime(2026, 10, 5));
      expect(start.weekday, DateTime.monday);
    });

    test('monthly is the first of the month', () {
      expect(bucketStartFor(DisplayGranularity.monthly, today),
          DateTime(2026, 10, 1));
    });

    test('a Sunday belongs to the Monday before it, not after', () {
      // Sun Oct 11 2026 is in the week starting Mon Oct 5.
      final sunday = DateTime(2026, 10, 11);
      expect(bucketStartFor(DisplayGranularity.weekly, sunday),
          DateTime(2026, 10, 5));
    });
  });

  group('granularityForScale', () {
    test('fixed scales fold onto the three waterfall buckets', () {
      expect(granularityForScale(TimeScale.daily), DisplayGranularity.daily);
      expect(granularityForScale(TimeScale.weekly), DisplayGranularity.weekly);
      expect(granularityForScale(TimeScale.biweekly), DisplayGranularity.weekly);
      expect(granularityForScale(TimeScale.monthly), DisplayGranularity.monthly);
      expect(granularityForScale(TimeScale.quarterly),
          DisplayGranularity.monthly);
      expect(granularityForScale(TimeScale.yearly),
          DisplayGranularity.monthly);
      expect(granularityForScale(TimeScale.custom),
          DisplayGranularity.monthly);
    });
  });

  group('groupLedgerEntries', () {
    const t = GranularityThresholds(
        monthlyThresholdDays: 60, weeklyThresholdDays: 7);

    test('empty input produces no buckets', () {
      expect(
          groupLedgerEntries(
              rows: const [], thresholds: t, today: today),
          isEmpty);
    });

    test('every row ends up in exactly one bucket, in order', () {
      final rows = [
        row('near1', today), // 0 out   → daily,  Oct 7
        row('near2', today.add(const Duration(days: 2))), // 2 out → daily, Oct 9
        row('far1', today.add(const Duration(days: 45))), // 45 out → weekly
        row('far2', today.add(const Duration(days: 80))), // 80 out → monthly
      ];
      final buckets = groupLedgerEntries(
          rows: rows, thresholds: t, today: today);
      expect(buckets.length, 4);
      expect(buckets.map((b) => b.granularity).toList(), [
        DisplayGranularity.daily,
        DisplayGranularity.daily,
        DisplayGranularity.weekly,
        DisplayGranularity.monthly,
      ]);
      // Nothing dropped or duplicated.
      expect(buckets.expand((b) => b.entries).map((e) => e.sourceId).toList(),
          rows.map((e) => e.sourceId).toList());
    });

    test('near rows bucket by day, so different days do not merge', () {
      final rows = [
        row('a', today),
        row('b', today.add(const Duration(days: 1))),
        row('c', today.add(const Duration(days: 2))),
      ];
      final buckets = groupLedgerEntries(
          rows: rows, thresholds: t, today: today);
      expect(buckets.length, 3);
      for (final b in buckets) {
        expect(b.granularity, DisplayGranularity.daily);
        expect(b.entries.length, 1);
      }
    });

    test('far rows bucket by month', () {
      // All well past the 60-day monthly threshold, so each resolves to
      // monthly; only the month differs.
      final rows = [
        row('a', DateTime(2027, 1, 3)), // 88 out
        row('b', DateTime(2027, 1, 28)), // 113 out
        row('c', DateTime(2027, 2, 9)), // 125 out
      ];
      final buckets = groupLedgerEntries(
          rows: rows, thresholds: t, today: today);
      expect(buckets.length, 2);
      expect(buckets.first.bucketStart, DateTime(2027, 1, 1));
      expect(buckets.first.entries.map((e) => e.sourceId), ['a', 'b']);
      expect(buckets.last.bucketStart, DateTime(2027, 2, 1));
    });

    test('buckets aggregate a total but keep the entries', () {
      // The spec's rule: the view may aggregate for readability, the
      // underlying model keeps the granular rows.
      final rows = [
        row('a', DateTime(2027, 1, 3), amount: -10),
        row('b', DateTime(2027, 1, 28), amount: -32.5),
        row('c', DateTime(2027, 1, 15), amount: 100),
      ];
      final buckets = groupLedgerEntries(
          rows: rows, thresholds: t, today: today);
      expect(buckets.length, 1);
      final bucket = buckets.single;
      expect(bucket.netAmount, closeTo(57.5, 0.0001));
      expect(bucket.entries.length, 3);
      expect(bucket.entries.map((e) => e.sourceId).toSet(), {'a', 'b', 'c'});
    });

    test('a single-row bucket is not collapsible', () {
      final buckets = groupLedgerEntries(
        rows: [row('solo', today)],
        thresholds: t,
        today: today,
      );
      expect(buckets.single.isCollapsible, isFalse);
    });

    test('hasConfirmed distinguishes real money from projections', () {
      final projected = row('p', DateTime(2027, 1, 3));
      final confirmed = LedgerEntry(
        sourceId: 'c',
        name: 'c',
        amount: -5,
        date: DateTime(2027, 1, 4),
        type: EntryType.transaction,
        status: EntryStatus.confirmed,
      );
      final buckets = groupLedgerEntries(
        rows: [projected, confirmed],
        thresholds: t,
        today: today,
      );
      expect(buckets.single.hasConfirmed, isTrue);
    });

    test('runningBalance is the newest entry in the bucket', () {
      final withBalances = [
        LedgerEntry(
          sourceId: 'newest',
          name: 'newest',
          amount: -10,
          date: DateTime(2027, 1, 5),
          type: EntryType.expense,
          status: EntryStatus.projected,
          runningBalance: 500,
        ),
        LedgerEntry(
          sourceId: 'older',
          name: 'older',
          amount: -10,
          date: DateTime(2027, 1, 3),
          type: EntryType.expense,
          status: EntryStatus.projected,
          runningBalance: 510,
        ),
      ];
      final buckets = groupLedgerEntries(
          rows: withBalances, thresholds: t, today: today);
      // entries[0] is the newest in display order (newest-first).
      expect(buckets.single.runningBalance, 500);
    });

    test('fixed scale buckets everything at one granularity', () {
      final rows = [
        row('near', today),
        row('mid', today.add(const Duration(days: 20))),
        row('far', today.add(const Duration(days: 200))),
      ];
      final buckets = groupLedgerEntries(
        rows: rows,
        thresholds: t,
        today: today,
        fixedScale: TimeScale.monthly,
      );
      expect(buckets.every((b) => b.granularity == DisplayGranularity.monthly),
          isTrue);
      // One bucket per distinct month, so three rows span several.
      expect(
          buckets.map((b) => b.bucketStart.month).toSet().length,
          greaterThan(1));
    });

    test('changing thresholds regroups the same rows', () {
      final rows = [row('a', today.add(const Duration(days: 20)))];
      final narrow = groupLedgerEntries(
          rows: rows, thresholds: t, today: today);
      final wide = groupLedgerEntries(
        rows: rows,
        thresholds: const GranularityThresholds(
            monthlyThresholdDays: 365, weeklyThresholdDays: 30),
        today: today,
      );
      expect(narrow.single.granularity, DisplayGranularity.weekly);
      expect(wide.single.granularity, DisplayGranularity.daily);
    });

    test('large runs retain every row and separate bucket buffers', () {
      final first = List.generate(10000, (i) => row('$i', today));
      final nextDay = row('next', today.add(const Duration(days: 1)));
      final buckets = groupLedgerEntries(
        rows: [...first, nextDay],
        thresholds: t,
        today: today,
      );
      expect(buckets, hasLength(2));
      expect(buckets.first.entries, orderedEquals(first));
      expect(buckets.last.entries, [nextDay]);
      expect(identical(buckets.first.entries.first, first.first), isTrue);
      expect(identical(buckets.first.entries.last, first.last), isTrue);
    });

    test('LedgerBucket supports value equality', () {
      final b1 = LedgerBucket(
        granularity: DisplayGranularity.daily,
        bucketStart: DateTime(2026, 10, 7),
        entries: [row('a', today)],
      );
      final b2 = LedgerBucket(
        granularity: DisplayGranularity.daily,
        bucketStart: DateTime(2026, 10, 7),
        entries: [row('a', today)],
      );
      final b3 = LedgerBucket(
        granularity: DisplayGranularity.weekly,
        bucketStart: DateTime(2026, 10, 7),
        entries: [row('a', today)],
      );
      // Unequal in bucketStart and entries as well, not just granularity.
      final b4 = LedgerBucket(
        granularity: DisplayGranularity.daily,
        bucketStart: DateTime(2026, 10, 8),
        entries: [row('a', today)],
      );
      final b5 = LedgerBucket(
        granularity: DisplayGranularity.daily,
        bucketStart: DateTime(2026, 10, 7),
        entries: [row('b', today)],
      );
      expect(b1, equals(b2));
      expect(b1.hashCode, equals(b2.hashCode));
      expect(b1, isNot(equals(b3)));
      expect(b1, isNot(equals(b4)));
      expect(b1, isNot(equals(b5)));
    });

    test('grouping the same rows twice yields equal bucket lists', () {
      // Fresh objects both times (as rebuild() produces), still equal —
      // so a redundant rebuild compares equal and Bloc suppresses the
      // emit (no redundant HydratedBloc disk write).
      List<LedgerBucket> build() => groupLedgerEntries(
            rows: [
              row('a', DateTime(2027, 1, 3), amount: -10),
              row('b', DateTime(2027, 1, 28), amount: -32.5),
            ],
            thresholds: t,
            today: today,
          );
      expect(build(), build());
    });

    test('WaterfallStates with identically built buckets compare equal', () {
      WaterfallState build() {
        final rows = [row('a', DateTime(2027, 1, 3))];
        return WaterfallState(
          projectionHorizon: DateTime(2027, 6, 1),
          rows: rows,
          buckets: groupLedgerEntries(
            rows: rows,
            thresholds: const GranularityThresholds(),
            today: today,
          ),
        );
      }
      expect(build(), build());
    });
  });
}
