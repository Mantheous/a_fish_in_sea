import 'package:a_fish_in_sea/planner/bloc/calendar_visibility_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/calendar_report.dart';
import 'package:a_fish_in_sea/planner/view/calendar_projection.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:flutter_test/flutter_test.dart';

PlannerEvent _event(String id, DateTime start) => PlannerEvent(
  id: id,
  subject: 'Event $id',
  start: start,
  end: start.add(const Duration(hours: 1)),
);

ReportedEntry _accepted({
  required String id,
  required DateTime start,
  required DateTime end,
  String? eventId,
}) => ReportedEntry(
  id: id,
  eventId: eventId,
  title: 'Report $id',
  start: start,
  end: end,
  status: ReportStatus.attended,
  auto: false,
);

void main() {
  group('CalendarProjection report columns', () {
    late CalendarProjection projection;
    final day = DateTime(2026, 10, 5);
    final event = _event('e1', DateTime(2026, 10, 5, 9));
    final allDay = PlannerEvent(
      id: 'allday-1',
      subject: 'Conference',
      start: DateTime(2026, 10, 5),
      end: DateTime(2026, 10, 6),
      allDay: true,
    );
    final reports = <String, List<ReportedEntry>>{
      '2026-10-05': [
        _accepted(
          id: 'r1',
          eventId: 'e1',
          start: DateTime(2026, 10, 5, 9, 5),
          end: DateTime(2026, 10, 5, 9, 45),
        ),
      ],
    };

    void update({
      bool showReportLanes = true,
      List<DateTime> visibleDays = const [],
      double startHour = 6,
      double endHour = 24,
      List<PlannerEvent>? events,
    }) {
      projection.update(
        events: events ?? [event, allDay],
        feeds: const [],
        visibility: const CalendarVisibilityState(),
        nodes: const [],
        reports: reports,
        showReports: true,
        showReportLanes: showReportLanes,
        visibleDays: visibleDays,
        visibleStartHour: startHour,
        visibleEndHour: endHour,
        now: DateTime(2026, 10, 5, 12),
      );
    }

    setUp(() => projection = CalendarProjection());

    test('the report column replaces report appointments in `shown`', () {
      update(visibleDays: [day]);
      // Plans keep the grid to themselves: no report tiles.
      expect(projection.shown.map((e) => e.id), ['e1', 'allday-1']);
      expect(projection.reportBlocksByDay.keys, [day]);
      expect(projection.reportBlocksByDay[day], hasLength(1));
      expect(projection.reportById.keys, ['report:r1']);
      expect(projection.reportColorById, hasLength(1));
      expect(projection.shown.any((e) => isReportDisplayId(e.id)), isFalse);
    });

    test('one lane per visible day, even when a day has no reports', () {
      update(
        visibleDays: [
          for (var i = 0; i < 7; i++)
            DateTime(2026, 10, 5).add(Duration(days: i)),
        ],
      );
      expect(projection.reportBlocksByDay, hasLength(7));
      expect(projection.reportBlocksByDay[DateTime(2026, 10, 5)], hasLength(1));
      expect(projection.reportBlocksByDay[DateTime(2026, 10, 6)], isEmpty);
    });

    test('month-style mode keeps report blocks as appointments', () {
      update(showReportLanes: false);
      expect(projection.shown.map((e) => e.id), [
        'e1',
        'allday-1',
        'report:r1',
      ]);
      expect(projection.reportBlocksByDay, isEmpty);
    });

    test('blocks outside the visible grid hours are not placed in a lane', () {
      final late = <String, List<ReportedEntry>>{
        '2026-10-05': [
          _accepted(
            id: 'r2',
            eventId: 'e1',
            start: DateTime(2026, 10, 5, 2),
            end: DateTime(2026, 10, 5, 3),
          ),
        ],
      };
      projection.update(
        events: [event],
        feeds: const [],
        visibility: const CalendarVisibilityState(),
        nodes: const [],
        reports: late,
        showReports: true,
        showReportLanes: true,
        visibleDays: [day],
        visibleStartHour: 6,
        visibleEndHour: 24,
        now: DateTime(2026, 10, 5, 12),
      );
      expect(projection.reportBlocksByDay.keys, [day]);
      expect(projection.reportBlocksByDay[day], isEmpty);
      expect(projection.reportById, isNotEmpty);
    });
  });
}
