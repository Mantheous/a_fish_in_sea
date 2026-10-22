import '../model/node.dart';
import '../../planner/model/planner_event.dart';

/// Builds the schedule facet that mirrors an imported calendar event.
/// Keep the all-day flag and full event window alongside any chosen due date.
ScheduleFacet scheduleForEvent(PlannerEvent event, {DateTime? due}) =>
    ScheduleFacet(
      due: due ?? event.start,
      start: event.start,
      end: event.end,
      allDay: event.allDay,
    );
