import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/planner/model/ical_recurrence.dart';
import 'package:a_fish_in_sea/planner/model/recurrence.dart';

/// How faithful a conversion between two recurrence vocabularies is.
///
/// Every conversion across vocabularies loses *something*; this enum makes
/// each loss explicit and testable instead of hiding it in a cast.
enum ConversionFidelity {
  /// The target says exactly what the source said.
  exact,

  /// The target carries the same period but a different (weaker or
  /// stronger) constraint, so the round trip does not return the source.
  lossy,

  /// The target vocabulary cannot express this at all.
  unsupported,
}

/// The declared mapping between two recurrence vocabularies.
class FrequencyMapping {
  final ConversionFidelity fidelity;

  /// Why the mapping is [ConversionFidelity.lossy] or
  /// [ConversionFidelity.unsupported]. Always non-null for those two —
  /// a test asserts it, so no conversion can be lossy in silence.
  final String? reason;

  const FrequencyMapping._(this.fidelity, this.reason);

  const FrequencyMapping.exact() : this._(ConversionFidelity.exact, null);

  const FrequencyMapping.lossy(String reason)
      : this._(ConversionFidelity.lossy, reason);

  const FrequencyMapping.unsupported(String reason)
      : this._(ConversionFidelity.unsupported, reason);

  bool get isExact => fidelity == ConversionFidelity.exact;
  bool get isUnsupported => fidelity == ConversionFidelity.unsupported;
}

/// The single place the three recurrence vocabularies meet.
///
/// Before this file the app carried three overlapping period vocabularies
/// that nothing mapped between:
///
///  - [TimeScale] — recurring rules, budget templates, view granularity.
///    Has `quarterly` and `custom`.
///  - [RepeatKind] — planner calendar events. Has `weekdays` and `none`.
///  - [ICalFrequency] — raw iCalendar, down to `secondly`.
///
/// Every boundary (iCal import, template instance generation, view scale
/// selection) re-derived the relationship ad hoc or silently dropped a
/// value. These extensions declare that mapping once.
///
/// The lesson taken from the Project Time Management Ontology is that the
/// difference between a model and a pile of models is *declared*
/// relationships. [FrequencyMapping] forces every conversion to say which
/// of the three fidelities it is, so a silent widening cannot sneak in.
extension TimeScaleFrequency on TimeScale {
  /// Maps to the planner's event vocabulary, or null when [RepeatKind]
  /// cannot express this scale.
  RepeatKind? toRepeatKind() {
    switch (this) {
      case TimeScale.daily:
        return RepeatKind.daily;
      case TimeScale.weekly:
        return RepeatKind.weekly;
      case TimeScale.biweekly:
        return RepeatKind.biweekly;
      case TimeScale.monthly:
        return RepeatKind.monthly;
      case TimeScale.yearly:
        return RepeatKind.yearly;
      case TimeScale.quarterly:
      case TimeScale.custom:
        return null;
    }
  }

  /// Says why [toRepeatKind] returned what it returned.
  FrequencyMapping repeatMapping() {
    switch (this) {
      case TimeScale.daily:
      case TimeScale.weekly:
      case TimeScale.biweekly:
      case TimeScale.monthly:
      case TimeScale.yearly:
        return const FrequencyMapping.exact();
      case TimeScale.quarterly:
        return const FrequencyMapping.unsupported(
            'RepeatKind has no quarterly, and WEEKLY;INTERVAL=13 does not '
            'fit its biweekly-only interval handling, so it is not '
            'approximated to monthly.');
      case TimeScale.custom:
        return const FrequencyMapping.unsupported(
            'A user-defined period has no fixed calendar equivalent.');
    }
  }

  /// The bare iCalendar FREQ value for this scale, or null when the scale
  /// cannot be carried by a frequency alone.
  ICalFrequency? toICalFrequency() {
    switch (this) {
      case TimeScale.daily:
        return ICalFrequency.daily;
      case TimeScale.weekly:
      case TimeScale.biweekly:
        return ICalFrequency.weekly;
      case TimeScale.monthly:
        return ICalFrequency.monthly;
      case TimeScale.yearly:
        return ICalFrequency.yearly;
      case TimeScale.quarterly:
      case TimeScale.custom:
        return null;
    }
  }

  /// iCalendar INTERVAL for this scale: 1 for every scale except
  /// biweekly, which is a weekly rule every 2 weeks.
  int toICalInterval() => this == TimeScale.biweekly ? 2 : 1;

  FrequencyMapping iCalMapping() {
    switch (this) {
      case TimeScale.daily:
      case TimeScale.weekly:
      case TimeScale.monthly:
      case TimeScale.yearly:
        return const FrequencyMapping.exact();
      case TimeScale.biweekly:
        return const FrequencyMapping.lossy(
            'Expressed as FREQ=WEEKLY;INTERVAL=2 — the scale rides on the '
            'interval, not on the frequency.');
      case TimeScale.quarterly:
      case TimeScale.custom:
        return const FrequencyMapping.unsupported(
            'A quarterly or user-defined period is not an iCalendar FREQ; '
            'it would need BYMONTH or INTERVAL on a monthly rule.');
    }
  }
}

extension RepeatKindFrequency on RepeatKind {
  /// Maps to the canonical scale, or null when the kind is not a period
  /// at all (no recurrence).
  TimeScale? toTimeScale() {
    switch (this) {
      case RepeatKind.none:
        return null;
      case RepeatKind.daily:
        return TimeScale.daily;
      case RepeatKind.weekdays:
      case RepeatKind.weekly:
        return TimeScale.weekly;
      case RepeatKind.biweekly:
        return TimeScale.biweekly;
      case RepeatKind.monthly:
        return TimeScale.monthly;
      case RepeatKind.yearly:
        return TimeScale.yearly;
    }
  }

  FrequencyMapping timeScaleMapping() {
    switch (this) {
      case RepeatKind.none:
        return const FrequencyMapping.unsupported(
            'No recurrence at all — this is not a period.');
      case RepeatKind.daily:
      case RepeatKind.weekly:
      case RepeatKind.biweekly:
      case RepeatKind.monthly:
      case RepeatKind.yearly:
        return const FrequencyMapping.exact();
      case RepeatKind.weekdays:
        return const FrequencyMapping.lossy(
            'weekdays is a weekly rule restricted to Mon-Fri; TimeScale '
            'carries the period (weekly) but loses the BYDAY restriction.');
    }
  }

  /// The bare iCalendar FREQ value for this kind, or null when the kind
  /// carries no recurrence. BYDAY / BYMONTHDAY still have to be added by
  /// [RepeatConfig.ruleFor] — this is only the frequency.
  ICalFrequency? toICalFrequency() {
    switch (this) {
      case RepeatKind.none:
        return null;
      case RepeatKind.daily:
        return ICalFrequency.daily;
      case RepeatKind.weekdays:
      case RepeatKind.weekly:
      case RepeatKind.biweekly:
        return ICalFrequency.weekly;
      case RepeatKind.monthly:
        return ICalFrequency.monthly;
      case RepeatKind.yearly:
        return ICalFrequency.yearly;
    }
  }
}

extension ICalFrequencyMapping on ICalFrequency {
  /// Maps to the canonical scale, or null for sub-daily frequencies the
  /// app has no granularity for.
  TimeScale? toTimeScale() {
    switch (this) {
      case ICalFrequency.secondly:
      case ICalFrequency.minutely:
      case ICalFrequency.hourly:
        return null;
      case ICalFrequency.daily:
        return TimeScale.daily;
      case ICalFrequency.weekly:
        return TimeScale.weekly;
      case ICalFrequency.monthly:
        return TimeScale.monthly;
      case ICalFrequency.yearly:
        return TimeScale.yearly;
    }
  }

  FrequencyMapping timeScaleMapping() {
    switch (this) {
      case ICalFrequency.secondly:
      case ICalFrequency.minutely:
      case ICalFrequency.hourly:
        return const FrequencyMapping.unsupported(
            'Sub-daily frequencies have no TimeScale; the app has no '
            'granularity finer than a day.');
      case ICalFrequency.daily:
      case ICalFrequency.weekly:
      case ICalFrequency.monthly:
      case ICalFrequency.yearly:
        return const FrequencyMapping.lossy(
            'The frequency maps cleanly, but a bare frequency drops the '
            'iCal INTERVAL, COUNT and BY* parts — use '
            'repeatConfigFromICal for the full conversion.');
    }
  }
}
