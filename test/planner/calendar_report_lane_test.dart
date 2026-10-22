import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/calendar_report.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:a_fish_in_sea/planner/view/calendar_report_lane.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

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

    test('placeholder ids are recognised and never read as lanes', () {
      final id = '${reportPlaceholderIdPrefix}personal-1';
      expect(isReportPlaceholderId(id), isTrue);
      expect(isReportLaneId(id), isFalse);
      expect(reportLaneDayOf(id), isNull);
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
      expect(grouped[monday]!.map((b) => b.displayId), [
        'report:a',
        'report:b',
      ]);
      expect(grouped[DateTime(2026, 10, 6)]!.map((b) => b.displayId), [
        'report:c',
      ]);
    });
  });

  group('Plan + Report calendar layout', () {
    double timeGridTopIn(WidgetTester tester, Finder calendarFinder) {
      final candidates = find.descendant(
        of: calendarFinder,
        matching: find.byType(Scrollable),
      );
      for (var i = 0; i < candidates.evaluate().length; i++) {
        final state = tester.state<ScrollableState>(candidates.at(i));
        if (state.position.axis != Axis.vertical ||
            state.position.viewportDimension <= 100 ||
            state.position.maxScrollExtent <= 0) {
          continue;
        }
        final render = state.context.findRenderObject();
        if (render is RenderBox && render.hasSize) {
          return render.localToGlobal(Offset.zero).dy;
        }
      }
      fail('no time-grid viewport in the calendar');
    }

    testWidgets('each day places its report to the right of its plan', (
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
      // Two frames: the first rebuilds the calendar, the second lets
      // SfCalendar run its appointment layout pass.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Plan + Report'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      // Two calendars share one grid: the plan track is left and the report
      // track is directly beside it in the same day cell.
      expect(find.byType(SfCalendar), findsNWidgets(2));
      final railFinder = find.byType(ReportLaneView);
      expect(
        railFinder,
        findsOneWidget,
        reason: 'the visible day should own a report lane',
      );
      // Report blocks are not tiles in the plan grid any more.
      expect(find.byKey(const ValueKey('tile:report:r1')), findsNothing);
      expect(find.text('Report r1'), findsOneWidget);

      final railRect = tester.getRect(railFinder);
      final tileRect = tester.getRect(find.byKey(const ValueKey('tile:e1')));
      expect(tileRect.left, lessThan(railRect.left));
      expect(tileRect.right, lessThanOrEqualTo(railRect.left + 1));
      expect(tileRect.width, closeTo(railRect.width, 4));

      // Both grids share one time axis: a chip at 9:05 lines up with the
      // 9:00 planned tile in the other calendar.
      expect(find.text('9:05 AM – 9:50 AM · accepted'), findsOneWidget);
      final chipRect = tester.getRect(
        find.byKey(const ValueKey('report-chip:report:r1')),
      );
      expect(tileRect.right, lessThanOrEqualTo(chipRect.left + 2));
      expect(chipRect.top - tileRect.top, closeTo(6.7, 6));
      expect(chipRect.height, closeTo(60, 6));

      // Scrolling one grid scrolls the other, to the same offset.
      final planScroll = Scrollable.maybeOf(
        tester.element(find.byKey(const ValueKey('tile:e1'))),
      )!.position;
      final railScroll = Scrollable.maybeOf(
        tester.element(railFinder),
      )!.position;
      planScroll.jumpTo(200);
      await tester.pump(const Duration(milliseconds: 200));
      expect(railScroll.pixels, planScroll.pixels);
      railScroll.jumpTo(120);
      await tester.pump(const Duration(milliseconds: 200));
      expect(planScroll.pixels, railScroll.pixels);
    });

    testWidgets('week view keeps a report column per visible day', (
      tester,
    ) async {
      await pumpGoldenPage(tester, const CalendarPage());
      final context = tester.element(find.byType(CalendarPage));
      final calendar = context.read<CalendarCubit>();
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day, 9);
      calendar.addEvent(_event('e1', start));
      final spanStart = DateTime(now.year, now.month, now.day - 1);
      calendar.addEvent(
        PlannerEvent(
          id: 'allday-span',
          subject: 'Conference',
          start: spanStart,
          end: spanStart.add(const Duration(days: 3)),
          allDay: true,
        ),
      );
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
      await tester.tap(find.text('Week'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(ReportLaneView), findsNWidgets(7));
      // The chip and its planned event still share one time axis. In a week
      // column the chip is too narrow for text, so it is found by key.
      final tileRect = tester.getRect(find.byKey(const ValueKey('tile:e1')));
      final chipRect = tester.getRect(
        find.byKey(const ValueKey('report-chip:report:r1')),
      );
      expect(tileRect.right, lessThanOrEqualTo(chipRect.left + 2));
      expect(chipRect.top - tileRect.top, closeTo(6.7, 6));
    });

    testWidgets('overlapping plans stay in the plan half and remain tappable', (
      tester,
    ) async {
      await pumpGoldenPage(tester, const CalendarPage());
      final context = tester.element(find.byType(CalendarPage));
      final calendar = context.read<CalendarCubit>();
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day, 9);
      calendar.addEvent(_event('e1', start));
      calendar.addEvent(_event('e2', start));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Plan + Report'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      final first = tester.getRect(find.byKey(const ValueKey('tile:e1')));
      final second = tester.getRect(find.byKey(const ValueKey('tile:e2')));
      final report = tester.getRect(find.byType(ReportLaneView).first);
      expect(first.right, lessThanOrEqualTo(report.left + 1));
      expect(second.right, lessThanOrEqualTo(report.left + 1));
      expect(first.left, lessThan(second.left));
      expect(first.right, lessThanOrEqualTo(second.left + 1));

      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('tile:e2'))),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Event details'), findsOneWidget);
      expect(find.text('Event e2'), findsWidgets);
    });

    testWidgets('an overlapping plan can still be dragged', (tester) async {
      await pumpGoldenPage(tester, const CalendarPage());
      final context = tester.element(find.byType(CalendarPage));
      final calendar = context.read<CalendarCubit>();
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day, 9);
      calendar.addEvent(_event('e1', start));
      calendar.addEvent(_event('e2', start));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Plan + Report'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      final tile = find.byKey(const ValueKey('tile:e2'));
      final center = tester.getCenter(tile);
      final gesture = await tester.startGesture(center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(center + const Offset(0, 120));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(calendar.byId('e2')!.start.isAfter(start), isTrue);
    });

    testWidgets('wheel scrolling over a paired plan tile stays in the grid', (
      tester,
    ) async {
      await pumpGoldenPage(tester, const CalendarPage());
      final context = tester.element(find.byType(CalendarPage));
      final calendar = context.read<CalendarCubit>();
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day, 9);
      calendar.addEvent(_event('e1', start));
      calendar.addEvent(_event('e2', start));
      context.read<ReportingCubit>().upsertEntry(
        DateTime(now.year, now.month, now.day),
        _accepted(
          id: 'wheel-report',
          eventId: 'e2',
          start: start.add(const Duration(minutes: 5)),
          end: start.add(const Duration(minutes: 50)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Plan + Report'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      final tileFinder = find.byKey(const ValueKey('tile:e2'));
      final chipFinder = find.byKey(
        const ValueKey('report-chip:report:wheel-report'),
      );
      final gridTop = timeGridTopIn(
        tester,
        find.byKey(const Key('plan-calendar')),
      );
      final tileBefore = tester.getRect(tileFinder);
      final chipBefore = tester.getRect(chipFinder);
      final offsetBefore = chipBefore.top - tileBefore.top;
      final pointer = tester.getCenter(tileFinder);
      tester.binding.handlePointerEvent(
        PointerScrollEvent(position: pointer, scrollDelta: const Offset(0, 60)),
      );
      await tester.pump(const Duration(milliseconds: 100));

      final tileAfter = tester.getRect(tileFinder);
      final chipAfter = tester.getRect(chipFinder);
      expect(tileAfter.top, lessThan(tileBefore.top));
      expect(chipAfter.top, lessThan(chipBefore.top));
      expect(chipAfter.top - tileAfter.top, closeTo(offsetBefore, 1));
      expect(tileAfter.top, lessThan(gridTop));
      await tester.tapAt(Offset(tileAfter.center.dx, tileAfter.top + 4));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Event details'), findsNothing);
    });

    testWidgets('month view stays a single calendar with report chips', (
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
      await tester.tap(find.text('Month'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(SfCalendar), findsOneWidget);
      expect(find.byType(ReportLaneView), findsNothing);
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
