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
  if (due == null && !isFixed && !hasValidBlock) return null;
  return ScheduleFacet(
    due: due,
    start: hasValidBlock ? start : previous?.start,
    end: hasValidBlock ? end : previous?.end,
    allDay: hasValidBlock ? false : (previous?.allDay ?? false),
    isFixed: isFixed,
  );
}
