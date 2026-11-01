import '../model/planner_event.dart';

/// Moving a repeating Google event needs separate occurrence/series calls.
/// Keep the calendar fixed while allowing its other fields to be edited.
bool canChangeEventCalendar(PlannerEvent event, {required bool editable}) =>
    editable &&
    !event.isRecurringInstance &&
    !(event.isFromFeed && event.recurrenceRule.isNotEmpty);
