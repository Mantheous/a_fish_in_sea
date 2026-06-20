/// Unified time scale used across recurring rules, budget templates,
/// and view granularity controls.
///
/// The [custom] variant supports user-defined periods (e.g. semesters).
/// When [custom] is used, the associated model should store the period
/// duration separately (e.g. as a number of days or months).
enum TimeScale {
  daily,
  weekly,
  biweekly,
  monthly,
  quarterly,
  yearly,
  custom, // user-defined period, length stored alongside
}

/// Helper extensions for [TimeScale].
extension TimeScaleExtension on TimeScale {
  String get displayName {
    switch (this) {
      case TimeScale.daily:
        return 'Daily';
      case TimeScale.weekly:
        return 'Weekly';
      case TimeScale.biweekly:
        return 'Biweekly';
      case TimeScale.monthly:
        return 'Monthly';
      case TimeScale.quarterly:
        return 'Quarterly';
      case TimeScale.yearly:
        return 'Yearly';
      case TimeScale.custom:
        return 'Custom';
    }
  }

  /// Returns the approximate number of days for this scale.
  /// For [custom], returns 0 — callers must consult the custom period value.
  int get approximateDays {
    switch (this) {
      case TimeScale.daily:
        return 1;
      case TimeScale.weekly:
        return 7;
      case TimeScale.biweekly:
        return 14;
      case TimeScale.monthly:
        return 30;
      case TimeScale.quarterly:
        return 91;
      case TimeScale.yearly:
        return 365;
      case TimeScale.custom:
        return 0;
    }
  }
}
