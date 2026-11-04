import '../model/planner_event.dart';
import '../model/feed.dart';

/// Moving a repeating Google event needs separate occurrence/series calls.
/// Keep the calendar fixed while allowing its other fields to be edited.
bool canChangeEventCalendar(PlannerEvent event, {required bool editable}) =>
    editable &&
    !event.isRecurringInstance &&
    !(event.isFromFeed && event.recurrenceRule.isNotEmpty);

/// Explains which parts of an imported event are saved locally.
String eventSyncDescription(
  PlannerEvent event,
  Feed? feed, {
  required bool pushesToGoogle,
}) {
  if (pushesToGoogle) {
    return event.isRecurringInstance
        ? 'Part of a repeating series on ${feed?.name ?? 'Google'} — '
              'dragging moves just this occurrence, editing '
              'lets you pick this occurrence or the whole series.'
        : 'Synced with ${feed?.name ?? 'Google'} — edits save '
              'back to Google Calendar.';
  }
  return event.isTask
      ? 'Synced from ${feed?.name ?? 'your class'} — work times are saved '
            'on this device and kept when the class updates.'
      : 'Synced from ${feed?.name ?? 'your class'} — changes there '
            'will overwrite local edits on the next sync.';
}
