import 'package:equatable/equatable.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';

/// A repeating income or expense that auto-generates projected [Expense]
/// instances up to the projection horizon.
class RecurringRule extends Equatable {
  final String id;
  final String name;
  final double amount; // positive = income, negative = expense
  final TimeScale frequency;
  final int? customPeriodDays; // used when frequency == TimeScale.custom
  final DateTime startDate;
  final DateTime? endDate; // null = indefinite
  final String? category;
  final int? dayOfMonth; // for monthly: which day (1-28)
  final int? dayOfWeek; // for weekly: which day (1=Mon...7=Sun)

  const RecurringRule({
    required this.id,
    required this.name,
    required this.amount,
    required this.frequency,
    this.customPeriodDays,
    required this.startDate,
    this.endDate,
    this.category,
    this.dayOfMonth,
    this.dayOfWeek,
  });

  RecurringRule copyWith({
    String? id,
    String? name,
    double? amount,
    TimeScale? frequency,
    int? customPeriodDays,
    DateTime? startDate,
    DateTime? endDate,
    String? category,
    int? dayOfMonth,
    int? dayOfWeek,
  }) {
    return RecurringRule(
      id: id ?? this.id,
      name: name ?? this.name,
      amount: amount ?? this.amount,
      frequency: frequency ?? this.frequency,
      customPeriodDays: customPeriodDays ?? this.customPeriodDays,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      category: category ?? this.category,
      dayOfMonth: dayOfMonth ?? this.dayOfMonth,
      dayOfWeek: dayOfWeek ?? this.dayOfWeek,
    );
  }

  /// Generate projected [Expense] instances from [startDate] through [horizon].
  ///
  /// Only generates entries whose dates fall on or after [fromDate] and on or
  /// before [horizon]. Entries before [fromDate] are skipped (they should
  /// already be confirmed or irrelevant).
  List<Expense> generateExpenses({
    required DateTime fromDate,
    required DateTime horizon,
  }) {
    final expenses = <Expense>[];
    final effectiveEnd = endDate != null && endDate!.isBefore(horizon)
        ? endDate!
        : horizon;

    DateTime cursor = _firstOccurrenceOnOrAfter(startDate);
    int counter = 0;

    while (!cursor.isAfter(effectiveEnd)) {
      if (!cursor.isBefore(fromDate)) {
        expenses.add(Expense(
          id: '${id}_gen_$counter',
          name: name,
          amount: amount,
          date: cursor,
          category: category,
          sourceRuleId: id,
          status: ExpenseStatus.projected,
        ));
      }
      cursor = _nextOccurrence(cursor);
      counter++;

      // Safety valve: prevent infinite loops for misconfigured rules
      if (counter > 5000) break;
    }

    return expenses;
  }

  /// Returns the first occurrence date on or after [date], snapping to
  /// the configured day-of-month or day-of-week if applicable.
  DateTime _firstOccurrenceOnOrAfter(DateTime date) {
    switch (frequency) {
      case TimeScale.monthly:
        final day = dayOfMonth ?? date.day;
        var candidate = DateTime(date.year, date.month, day.clamp(1, 28));
        if (candidate.isBefore(date)) {
          candidate = DateTime(date.year, date.month + 1, day.clamp(1, 28));
        }
        return candidate;
      case TimeScale.weekly:
      case TimeScale.biweekly:
        final targetDay = dayOfWeek ?? date.weekday;
        var diff = targetDay - date.weekday;
        if (diff < 0) diff += 7;
        return date.add(Duration(days: diff));
      default:
        return date;
    }
  }

  /// Returns the next occurrence after [current].
  DateTime _nextOccurrence(DateTime current) {
    switch (frequency) {
      case TimeScale.daily:
        return current.add(const Duration(days: 1));
      case TimeScale.weekly:
        return current.add(const Duration(days: 7));
      case TimeScale.biweekly:
        return current.add(const Duration(days: 14));
      case TimeScale.monthly:
        final day = dayOfMonth ?? current.day;
        return DateTime(current.year, current.month + 1, day.clamp(1, 28));
      case TimeScale.quarterly:
        return DateTime(current.year, current.month + 3, current.day);
      case TimeScale.yearly:
        return DateTime(current.year + 1, current.month, current.day);
      case TimeScale.custom:
        final days = customPeriodDays ?? 30;
        return current.add(Duration(days: days));
    }
  }

  factory RecurringRule.fromJson(Map<String, dynamic> json) {
    return RecurringRule(
      id: json['id'] as String,
      name: json['name'] as String,
      amount: (json['amount'] as num).toDouble(),
      frequency: TimeScale.values.firstWhere(
        (e) => e.name == json['frequency'],
      ),
      customPeriodDays: json['customPeriodDays'] as int?,
      startDate: DateTime.parse(json['startDate'] as String),
      endDate: json['endDate'] != null
          ? DateTime.parse(json['endDate'] as String)
          : null,
      category: json['category'] as String?,
      dayOfMonth: json['dayOfMonth'] as int?,
      dayOfWeek: json['dayOfWeek'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'amount': amount,
        'frequency': frequency.name,
        'customPeriodDays': customPeriodDays,
        'startDate': startDate.toIso8601String(),
        'endDate': endDate?.toIso8601String(),
        'category': category,
        'dayOfMonth': dayOfMonth,
        'dayOfWeek': dayOfWeek,
      };

  @override
  List<Object?> get props => [
        id,
        name,
        amount,
        frequency,
        customPeriodDays,
        startDate,
        endDate,
        category,
        dayOfMonth,
        dayOfWeek,
      ];
}
