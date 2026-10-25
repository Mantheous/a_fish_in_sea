import 'package:equatable/equatable.dart';
import 'package:a_fish_in_sea/common/time/local_date.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';

/// A goal-based spending bucket for a recurring period.
///
/// Budgets track how much the user *intended* to spend vs how much they
/// *actually* spent.  At the end of each period, surplus or deficit can
/// optionally roll over into the next period.
class Budget extends Equatable {
  final String id;
  final String name;
  final String category;

  /// Target spending amount for each period (always positive).
  final double goalAmount;

  /// How often this budget resets (monthly, weekly, etc.).
  final TimeScale period;

  /// Custom period length in days when [period] == [TimeScale.custom].
  final int? customPeriodDays;

  final DateTime startDate;

  /// Null = indefinite (keeps recurring).
  final DateTime? endDate;

  /// Whether this budget recurs automatically.
  final bool isRecurring;

  /// Whether surplus/deficit automatically carries to the next period.
  /// Defaults to true for recurring budgets.
  final bool autoRollover;

  /// Accumulated surplus (positive) or deficit (negative) carried from
  /// previous periods.
  final double rolloverAmount;

  const Budget({
    required this.id,
    required this.name,
    required this.category,
    required this.goalAmount,
    required this.period,
    this.customPeriodDays,
    required this.startDate,
    this.endDate,
    this.isRecurring = true,
    this.autoRollover = true,
    this.rolloverAmount = 0.0,
  });

  /// Effective budget for the current period including rollover.
  double get effectiveAmount => goalAmount + rolloverAmount;

  Budget copyWith({
    String? id,
    String? name,
    String? category,
    double? goalAmount,
    TimeScale? period,
    int? customPeriodDays,
    DateTime? startDate,
    DateTime? endDate,
    bool clearEndDate = false,
    bool? isRecurring,
    bool? autoRollover,
    double? rolloverAmount,
  }) {
    return Budget(
      id: id ?? this.id,
      name: name ?? this.name,
      category: category ?? this.category,
      goalAmount: goalAmount ?? this.goalAmount,
      period: period ?? this.period,
      customPeriodDays: customPeriodDays ?? this.customPeriodDays,
      startDate: startDate ?? this.startDate,
      endDate: clearEndDate ? null : (endDate ?? this.endDate),
      isRecurring: isRecurring ?? this.isRecurring,
      autoRollover: autoRollover ?? this.autoRollover,
      rolloverAmount: rolloverAmount ?? this.rolloverAmount,
    );
  }

  /// Returns the start of the current budget period that contains [date].
  DateTime currentPeriodStart(DateTime date) {
    final day = localDay(date);
    switch (period) {
      case TimeScale.daily:
        return day;
      case TimeScale.weekly:
        final weekday = day.weekday; // 1=Mon
        return shiftLocalDay(day, -(weekday - 1));
      case TimeScale.biweekly:
        // Align to startDate's biweekly cadence. Calendar-day distance, not
        // elapsed hours: a DST change must not shift the period boundary.
        final start = localDay(startDate);
        final daysSinceStart = localDayDistance(start, day);
        final periodIndex = daysSinceStart ~/ 14;
        return shiftLocalDay(start, periodIndex * 14);
      case TimeScale.monthly:
        return DateTime(day.year, day.month, 1);
      case TimeScale.quarterly:
        final quarterMonth = ((day.month - 1) ~/ 3) * 3 + 1;
        return DateTime(day.year, quarterMonth, 1);
      case TimeScale.yearly:
        return DateTime(day.year, 1, 1);
      case TimeScale.custom:
        final days = customPeriodDays ?? 30;
        final start = localDay(startDate);
        final daysSinceStart = localDayDistance(start, day);
        final periodIndex = daysSinceStart ~/ days;
        return shiftLocalDay(start, periodIndex * days);
    }
  }

  /// Returns the inclusive end of the current budget period containing
  /// [date] (the last millisecond before the next period starts).
  DateTime currentPeriodEnd(DateTime date) {
    final start = currentPeriodStart(date);
    switch (period) {
      case TimeScale.daily:
        return shiftLocalDay(start, 1)
            .subtract(const Duration(milliseconds: 1));
      case TimeScale.weekly:
        return shiftLocalDay(start, 7)
            .subtract(const Duration(milliseconds: 1));
      case TimeScale.biweekly:
        return shiftLocalDay(start, 14)
            .subtract(const Duration(milliseconds: 1));
      case TimeScale.monthly:
        return DateTime(start.year, start.month + 1, 1)
            .subtract(const Duration(milliseconds: 1));
      case TimeScale.quarterly:
        return DateTime(start.year, start.month + 3, 1)
            .subtract(const Duration(milliseconds: 1));
      case TimeScale.yearly:
        return DateTime(start.year + 1, 1, 1)
            .subtract(const Duration(milliseconds: 1));
      case TimeScale.custom:
        final days = customPeriodDays ?? 30;
        return shiftLocalDay(start, days)
            .subtract(const Duration(milliseconds: 1));
    }
  }

  // ── Serialization ───────────────────────────────────────────────────

  factory Budget.fromJson(Map<String, dynamic> json) {
    return Budget(
      id: json['id'] as String,
      name: json['name'] as String,
      category: json['category'] as String,
      goalAmount: (json['goalAmount'] as num).toDouble(),
      period: TimeScale.values.firstWhere(
        (e) => e.name == json['period'],
        orElse: () => TimeScale.monthly,
      ),
      customPeriodDays: json['customPeriodDays'] as int?,
      startDate: DateTime.parse(json['startDate'] as String).toLocal(),
      endDate: json['endDate'] != null
          ? DateTime.parse(json['endDate'] as String).toLocal()
          : null,
      isRecurring: json['isRecurring'] as bool? ?? true,
      autoRollover: json['autoRollover'] as bool? ?? true,
      rolloverAmount: (json['rolloverAmount'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'category': category,
        'goalAmount': goalAmount,
        'period': period.name,
        'customPeriodDays': customPeriodDays,
        'startDate': startDate.toIso8601String(),
        'endDate': endDate?.toIso8601String(),
        'isRecurring': isRecurring,
        'autoRollover': autoRollover,
        'rolloverAmount': rolloverAmount,
      };

  @override
  List<Object?> get props => [
        id,
        name,
        category,
        goalAmount,
        period,
        customPeriodDays,
        startDate,
        endDate,
        isRecurring,
        autoRollover,
        rolloverAmount,
      ];
}
