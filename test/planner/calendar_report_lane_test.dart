import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_visibility_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/calendar_report.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:a_fish_in_sea/planner/view/calendar_projection.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../goldens/golden_app.dart';

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
  group('report lane ids', () {
    test('round-trip a day', () {
      final day = DateTime(2026, 10, 5);
      final id = reportLaneIdForDay(day);
      expect(isReportLaneId(id), isTrue);
      expect(reportLaneDayOf(id), day);
    });

    test('rejects ids that are not lanes or not real dates', () {
      expect(isReportLaneId('report:manual'), isFalse);
      expect(reportLaneDayOf('report:manual'), isNull);
      expect(reportLaneDayOf('reportlane:not-a-date'), isNull);
      expect(reportLaneDayOf('reportlane:2026-13-45'), isNull);
      expect(reportLaneDayOf('reportlane:2026-02-29'), isNull);
    });
  });

  group('findReportEntryByDisplayId', () {
    test('matches manual entries, ignores timer/live display ids', () {
      final reports = <String, List<ReportedEntry>>{
        '2026-10-05': [
          _accepted(
            id: 'r1',
            start: DateTime(2026, 10, 5, 9),
            end: DateTime(2026, 10, 5, 10),
          ),
        ],
      };
      expect(findReportEntryByDisplayId(reports, 'report:r1')?.id, 'r1');
      expect(findReportEntryByDisplayId(reports, 'report:timer:e1'), isNull);
      expect(findReportEntryByDisplayId(reports, 'report:live:e1'), isNull);
    });
  });

  group('groupReportBlocksByDay', () {
    test('keys blocks by the day they start on', () {
      final monday = DateTime(2026, 10, 5);
      final blocks = [
        ReportBlock(
          displayId: 'report:a',
          title: 'A',
          start: DateTime(2026, 10, 5, 9),
          end: DateTime(2026, 10, 5, 10),
          kind: ReportBlockKind.timer,
        ),
        ReportBlock(
          displayId: 'report:b',
          title: 'B',
          // Crosses midnight; stays with the day it started on.
          start: DateTime(2026, 10, 5, 23, 30),
          end: DateTime(2026, 10, 6, 0, 30),
          kind: ReportBlockKind.timer,
        ),
        ReportBlock(
          displayId: 'report:c',
          title: 'C',
          start: DateTime(2026, 10, 6, 8),
          end: DateTime(2026, 10, 6, 9),
          kind: ReportBlockKind.accepted,
        ),
      ];
      final grouped = groupReportBlocksByDay(blocks);
      expect(grouped[monday]!.map((b) => b.displayId), ['report:a', 'report:b']);
      expect(grouped[DateTime(2026, 10, 6)]!.map((b) => b.displayId), [
        'report:c',
      ]);
    });
  });

  group('CalendarProjection report lanes', () {
    late CalendarProjection projection;
    final day = DateTime(2026, 10, 5);
    final event = _event('e1', DateTime(2026, 10, 5, 9));
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
    }) {
      projection.update(
        events: [event],
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

    test('lane mode replaces report appointments with one lane per day', () {
      update(visibleDays: [day]);
      expect(projection.shown.map((e) => e.id), [
        'e1',
        reportLaneIdForDay(day),
      ]);
      expect(projection.reportBlocksByLaneId[reportLaneIdForDay(day)], hasLength(1));
      expect(projection.reportById.keys, ['report:r1']);
      expect(projection.reportColorById, hasLength(1));
      expect(
        projection.shown.any((e) => isReportDisplayId(e.id)),
        isFalse,
      );
    });

    test('one lane per visible day', () {
      update(
        visibleDays: [
          for (var i = 0; i < 7; i++)
            DateTime(2026, 10, 5).add(Duration(days: i)),
        ],
      );
      expect(
        projection.shown.where((e) => isReportLaneId(e.id)),
        hasLength(7),
      );
    });

    test('month-style mode keeps report blocks as appointments', () {
      update(showReportLanes: false);
      expect(projection.shown.map((e) => e.id), ['e1', 'report:r1']);
      expect(projection.reportBlocksByLaneId, isEmpty);
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
      expect(projection.shown.where((e) => isReportLaneId(e.id)), hasLength(1));
      expect(projection.reportBlocksByLaneId[reportLaneIdForDay(day)], isEmpty);
      expect(projection.reportById, isNotEmpty);
    });
  });

  group('Plan + Report calendar layout', () {
    testWidgets('each day gets its own report lane column', (tester) async {
      await pumpGoldenPage(tester, const CalendarPage());
      final context = tester.element(find.byType(CalendarPage));
      final calendar = context.read<CalendarCubit>();
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day, 9);
      calendar.addEvent(_event('e1', start));
      context.read<ReportingCubit>().upsertEntry(
        DateTime(now.year, now.month, now.day),
        _accepted(
          id: 'r1',
          eventId: 'e1',
          start: start.add(const Duration(minutes: 5)),
          end: start.add(const Duration(minutes: 50)),
        ),
      );
      // Two frames: the first rebuilds the calendar, the second lets
      // SfCalendar run its appointment layout pass.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Plan + Report'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      // Widget tests run as Android, where the calendar opens in the day
      // view: one visible day, one report lane.
      expect(
        find.byKey(const Key('report-lane')),
        findsOneWidget,
        reason: 'the visible day should own a report lane',
      );
      // The old behaviour halved every tile; the lane must not clip the
      // report to half of a planned tile's slot.
      expect(find.byKey(const ValueKey('tile:report:r1')), findsNothing);
      expect(find.text('Report r1'), findsOneWidget);

      final laneRect = tester.getRect(find.byKey(const Key('report-lane')));
      final tileRect = tester.getRect(find.byKey(const ValueKey('tile:e1')));
      // Report lane on the left, planned event's column beside it with the
      // same width — neither is squished to half of the other.
      expect(laneRect.left, lessThan(tileRect.left));
      expect(laneRect.right, lessThanOrEqualTo(tileRect.left + 1));
      expect((laneRect.width - tileRect.width).abs(), lessThan(12));
      expect(laneRect.height, greaterThan(tileRect.height * 4));

      // The chip sits at the report's own time, level with the planned
      // tile that starts at the same time: 9:05 on a 6 AM–midnight grid is
      // a few pixels below the 9:00 planned tile, and 45 minutes tall.
      expect(find.text('9:05 AM – 9:50 AM · accepted'), findsOneWidget);
      final chipRect = tester.getRect(
        find
            .ancestor(
              of: find.text('Report r1'),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(chipRect.top - tileRect.top, closeTo(6.7, 4));
      expect(chipRect.height, closeTo(60, 4));

      // Week view: one lane per visible day, and a day with no reports of
      // its own still keeps its lane on the left of that day's column.
      final monday = DateTime(
        now.year,
        now.month,
        now.day,
      ).add(const Duration(days: 1));
      final mondayStart = DateTime(monday.year, monday.month, monday.day, 10);
      calendar.addEvent(_event('e2', mondayStart));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Week'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      final laneFinder = find.byKey(const Key('report-lane'));
      expect(
        laneFinder,
        findsNWidgets(7),
        reason: 'each visible day should own a report lane',
      );
      final mondayRect = tester.getRect(
        find.byKey(const ValueKey('tile:e2')),
      );
      final laneRects = [
        for (var i = 0; i < 7; i++) tester.getRect(laneFinder.at(i)),
      ];
      final leftLane = laneRects.where(
        (rect) =>
            rect.left < mondayRect.left &&
            (rect.right - mondayRect.left).abs() < 2,
      );
      expect(
        leftLane,
        hasLength(1),
        reason: "Monday's plan sits in the column right of its own lane",
      );
      expect((leftLane.single.width - mondayRect.width).abs(), lessThan(12));
      expect(leftLane.single.top, lessThan(mondayRect.top));

      // Month view keeps report blocks as agenda chips (no lanes there).
      await tester.tap(find.text('Month'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('report-lane')), findsNothing);
      expect(
        find.byKey(const ValueKey('tile:report:r1')),
        findsWidgets,
        reason: 'month cells still show report blocks as tiny tiles',
      );
    });

    testWidgets('tapping a report chip opens the reported event', (
      tester,
    ) async {
      await pumpGoldenPage(tester, const CalendarPage());
      final context = tester.element(find.byType(CalendarPage));
      final calendar = context.read<CalendarCubit>();
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day, 9);
      calendar.addEvent(_event('e1', start));
      context.read<ReportingCubit>().upsertEntry(
        DateTime(now.year, now.month, now.day),
        _accepted(
          id: 'r1',
          eventId: 'e1',
          start: start.add(const Duration(minutes: 5)),
          end: start.add(const Duration(minutes: 50)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Plan + Report'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.text('Report r1'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Event details'), findsOneWidget);
    });
  });
}
