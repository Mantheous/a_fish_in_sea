import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/event_schedule.dart';
import 'package:a_fish_in_sea/nodes/service/node_editor_schedule.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('editor due-date changes preserve the existing calendar block', () {
    final previous = ScheduleFacet(
      due: DateTime(2026, 10, 20),
      start: DateTime(2026, 10, 18, 9),
      end: DateTime(2026, 10, 18, 10),
      allDay: true,
    );

    final saved = scheduleAfterEditorSave(
      previous: previous,
      due: DateTime(2026, 10, 22),
      isFixed: true,
    );

    expect(saved?.due, DateTime(2026, 10, 22));
    expect(saved?.start, previous.start);
    expect(saved?.end, previous.end);
    expect(saved?.allDay, isTrue);
  });

  test('event-derived schedules retain all-day windows', () {
    final event = PlannerEvent(
      id: 'e1',
      subject: 'Assignment',
      start: DateTime(2026, 10, 18),
      end: DateTime(2026, 10, 21),
      allDay: true,
    );

    final schedule = scheduleForEvent(event);

    expect(schedule.allDay, isTrue);
    expect(schedule.due, event.start);
    expect(schedule.end, event.end);
  });
}
