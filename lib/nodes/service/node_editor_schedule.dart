import '../model/node.dart';

/// Preserves a task's existing calendar window while the editor changes its
/// due date and fixed-date flag.
ScheduleFacet? scheduleAfterEditorSave({
  required ScheduleFacet? previous,
  required DateTime? due,
  required bool isFixed,
  DateTime? start,
  DateTime? end,
}) {
  final hasValidBlock = start != null && end != null && end.isAfter(start);
  // The editor only owns due/fixed; a block set from the calendar survives.
  // Checking only the *incoming* start/end dropped a block-only schedule on
  // every rename because the editor never passes those arguments.
  final hasPreservedBlock = previous?.hasCalendarBlock ?? false;
  if (due == null && !isFixed && !hasValidBlock && !hasPreservedBlock) {
    return null;
  }
  return ScheduleFacet(
    due: due,
    start: hasValidBlock ? start : previous?.start,
    end: hasValidBlock ? end : previous?.end,
    allDay: hasValidBlock ? false : (previous?.allDay ?? false),
    isFixed: isFixed,
  );
}
