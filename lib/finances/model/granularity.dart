import 'package:a_fish_in_sea/finances/model/ledger_entry.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';

/// The bucket sizes the Waterfall view is specified to use.
///
/// The product spec's Waterfall mode is defined as three scales only:
/// "far-future events at monthly granularity, near-future at weekly, and
/// current week at daily." Coarser [TimeScale] values (quarterly, yearly,
/// custom) have no waterfall bucket of their own — see
/// [granularityForScale], which folds them onto the monthly bucket rather
/// than inventing a fourth.
enum DisplayGranularity { daily, weekly, monthly }

/// The user-configurable cut-offs, in days, between the three waterfall
/// buckets.
///
/// `daysOut <= weeklyThresholdDays`  → [DisplayGranularity.daily]
/// `daysOut <= monthlyThresholdDays` → [DisplayGranularity.weekly]
/// anything further out             → [DisplayGranularity.monthly]
///
/// Both values are already persisted on [WaterfallState] and editable
/// through the tune dialog; before this file they were stored and never
/// read by any computation, so the spec's headline feature — dynamic
/// granularity by distance — was config-only.
class GranularityThresholds {
  final int monthlyThresholdDays;
  final int weeklyThresholdDays;

  const GranularityThresholds({
    this.monthlyThresholdDays = 60,
    this.weeklyThresholdDays = 7,
  });

  /// Which bucket a date [daysOut] days in the future falls into.
  ///
  /// Past dates are clamped to [DisplayGranularity.daily] so history
  /// stays as fine-grained as possible.
  DisplayGranularity resolve(int daysOut) {
    if (daysOut <= weeklyThresholdDays) return DisplayGranularity.daily;
    if (daysOut <= monthlyThresholdDays) return DisplayGranularity.weekly;
    return DisplayGranularity.monthly;
  }

  /// Same as [resolve] but takes a date, which is what callers have.
  DisplayGranularity resolveFor(DateTime date, DateTime today) =>
      resolve(_wholeDaysOut(date, today));

  /// The waterfall buckets these thresholds describe, coarsest first.
  List<DisplayGranularity> get activeScales => const [
        DisplayGranularity.monthly,
        DisplayGranularity.weekly,
        DisplayGranularity.daily,
      ];

  @override
  bool operator ==(Object other) =>
      other is GranularityThresholds &&
      other.monthlyThresholdDays == monthlyThresholdDays &&
      other.weeklyThresholdDays == weeklyThresholdDays;

  @override
  int get hashCode => Object.hash(monthlyThresholdDays, weeklyThresholdDays);
}

/// The bucket a fixed [TimeScale] view collapses onto.
///
/// Quarterly, yearly and custom have no finer bucket than monthly in the
/// waterfall spec, so they all display at monthly granularity rather
/// than silently showing everything at daily.
DisplayGranularity granularityForScale(TimeScale scale) {
  switch (scale) {
    case TimeScale.daily:
      return DisplayGranularity.daily;
    case TimeScale.weekly:
    case TimeScale.biweekly:
      return DisplayGranularity.weekly;
    case TimeScale.monthly:
    case TimeScale.quarterly:
    case TimeScale.yearly:
    case TimeScale.custom:
      return DisplayGranularity.monthly;
  }
}

/// The first instant of the bucket containing [date].
///
/// Weeks start on Monday, matching `Budget.currentPeriodStart` — the one
/// existing period implementation in the repo — so a budget row and a
/// ledger bucket covering the same week agree.
DateTime bucketStartFor(DisplayGranularity granularity, DateTime date) {
  switch (granularity) {
    case DisplayGranularity.daily:
      return DateTime(date.year, date.month, date.day);
    case DisplayGranularity.weekly:
      return DateTime(date.year, date.month, date.day - (date.weekday - 1));
    case DisplayGranularity.monthly:
      return DateTime(date.year, date.month, 1);
  }
}

/// A group of ledger rows displayed at one granularity.
///
/// The bucket holds *every* underlying entry it covers, unaggregated.
/// The view is free to show just the totals or to expand the membership;
/// the point of the type is that collapsing rows for readability can
/// never destroy the granular data behind them.
class LedgerBucket {
  final DisplayGranularity granularity;
  final DateTime bucketStart;

  /// The entries in this bucket, in the same (newest-first) order the
  /// waterfall displays them.
  final List<LedgerEntry> entries;

  const LedgerBucket({
    required this.granularity,
    required this.bucketStart,
    required this.entries,
  });

  bool get isCollapsible => entries.length > 1;

  /// Net cash-flow across the bucket. Negative = net spending.
  double get netAmount =>
      entries.fold(0.0, (sum, e) => sum + e.amount);

  /// Confirmed (real money) inside the bucket, ignoring projections.
  bool get hasConfirmed =>
      entries.any((e) => e.status == EntryStatus.confirmed);

  /// Running balance at the newest entry in the bucket — where the
  /// balance stands once the bucket is done.
  double get runningBalance => entries.isEmpty ? 0.0 : entries.first.runningBalance;

  /// Human-readable age, e.g. "3 days". Always taken from the newest
  /// entry, which is the one closest to now.
  String get timeUntilLabel =>
      entries.isEmpty ? '' : entries.first.timeUntilLabel;
}

/// Groups a waterfall's rows into buckets by distance from [today].
///
/// [rows] must already be in display order (newest first, which is what
/// [WaterfallCubit] emits). Buckets are formed from *runs* of consecutive
/// rows sharing a bucket start, so the returned list is in the same
/// order and every input row appears in exactly one bucket.
///
/// In waterfall mode the granularity steps down as rows get further out,
/// so runs are naturally contiguous: near dates bucket daily, mid-range
/// dates weekly, far dates monthly. In fixed-scale mode every row
/// resolves to the same granularity and only the dates differ.
List<LedgerBucket> groupLedgerEntries({
  required List<LedgerEntry> rows,
  required GranularityThresholds thresholds,
  required DateTime today,
  TimeScale? fixedScale,
}) {
  final buckets = <LedgerBucket>[];
  for (final row in rows) {
    final granularity = fixedScale == null
        ? thresholds.resolveFor(row.date, today)
        : granularityForScale(fixedScale);
    final start = bucketStartFor(granularity, row.date);
    if (buckets.isNotEmpty) {
      final last = buckets.last;
      if (last.granularity == granularity &&
          last.bucketStart.isAtSameMomentAs(start)) {
        buckets[buckets.length - 1] = LedgerBucket(
          granularity: granularity,
          bucketStart: last.bucketStart,
          entries: [...last.entries, row],
        );
        continue;
      }
    }
    buckets.add(LedgerBucket(
      granularity: granularity,
      bucketStart: start,
      entries: [row],
    ));
  }
  return buckets;
}

/// Whole days between two dates, ignoring the time of day. Negative for
/// dates in the past.
int _wholeDaysOut(DateTime date, DateTime today) {
  final from = DateTime(today.year, today.month, today.day);
  final to = DateTime(date.year, date.month, date.day);
  return to.difference(from).inDays;
}
