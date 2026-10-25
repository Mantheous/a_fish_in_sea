import 'package:equatable/equatable.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';

/// Recurrence for habit/budget templates. Only set on templates;
/// instances carry concrete dates + `instanceOfId`.
class NodeRecurrence extends Equatable {
  final TimeScale frequency;
  final int? customPeriodDays;
  final DateTime? endDate;
  final int? dayOfMonth;
  final int? dayOfWeek;

  const NodeRecurrence({
    required this.frequency,
    this.customPeriodDays,
    this.endDate,
    this.dayOfMonth,
    this.dayOfWeek,
  });

  NodeRecurrence copyWith({
    TimeScale? frequency,
    int? customPeriodDays,
    DateTime? endDate,
    bool clearEndDate = false,
    int? dayOfMonth,
    int? dayOfWeek,
  }) => NodeRecurrence(
    frequency: frequency ?? this.frequency,
    customPeriodDays: customPeriodDays ?? this.customPeriodDays,
    endDate: clearEndDate ? null : (endDate ?? this.endDate),
    dayOfMonth: dayOfMonth ?? this.dayOfMonth,
    dayOfWeek: dayOfWeek ?? this.dayOfWeek,
  );

  factory NodeRecurrence.fromJson(Map<String, dynamic> json) => NodeRecurrence(
    frequency: TimeScale.values.firstWhere(
      (e) => e.name == json['frequency'],
      orElse: () => TimeScale.daily,
    ),
    customPeriodDays: (json['customPeriodDays'] as num?)?.toInt().clamp(1, 36500).toInt(),
    endDate: _tryDate(json['endDate']),
    dayOfMonth: (json['dayOfMonth'] as num?)?.toInt(),
    dayOfWeek: (json['dayOfWeek'] as num?)?.toInt(),
  );

  Map<String, dynamic> toJson() => {
    'frequency': frequency.name,
    'customPeriodDays': customPeriodDays,
    'endDate': endDate?.toIso8601String(),
    'dayOfMonth': dayOfMonth,
    'dayOfWeek': dayOfWeek,
  };

  @override
  List<Object?> get props => [
    frequency,
    customPeriodDays,
    endDate,
    dayOfMonth,
    dayOfWeek,
  ];
}

DateTime? _tryDate(Object? raw) {
  if (raw is! String) return null;
  return DateTime.tryParse(raw)?.toLocal();
}
