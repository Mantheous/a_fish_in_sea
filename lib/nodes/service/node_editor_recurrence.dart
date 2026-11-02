import 'package:a_fish_in_sea/finances/model/time_scale.dart';

import '../model/node_recurrence.dart';

/// The editor owns the repeat switch, frequency, and end date. Preserve
/// imported interval and calendar-day settings that it does not expose.
NodeRecurrence? recurrenceAfterEditorSave({
  required NodeRecurrence? previous,
  required bool enabled,
  required TimeScale frequency,
  required DateTime? endDate,
}) {
  if (!enabled) return null;
  return (previous ?? NodeRecurrence(frequency: frequency)).copyWith(
    frequency: frequency,
    endDate: endDate,
    clearEndDate: endDate == null,
  );
}
