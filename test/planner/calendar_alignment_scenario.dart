import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:a_fish_in_sea/planner/view/report_chip.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

Future<void> verifyCalendarAlignment(
  WidgetTester tester,
  DateTime day,
  double startHour,
  String view, {
  String? golden,
}) async {
  final context = tester.element(find.byType(CalendarPage));
  context.read<SettingsCubit>().setDayHours(startHour, 24);
  await tester.tap(find.text(view));
  await tester.pumpAndSettle();
  final controller = tester
      .widget<SfCalendar>(find.byType(SfCalendar))
      .controller!;
  controller.displayDate = day;
  controller.selectedDate = day;
  final calendar = context.read<CalendarCubit>();
  for (var i = 0; i < 2; i++) {
    final start = DateTime(day.year, day.month, day.day, 8 + i);
    calendar.addEvent(
      PlannerEvent(
        id: 'p$i',
        subject: 'Plan $i',
        start: start,
        end: start.add(const Duration(hours: 1)),
      ),
    );
    context.read<ReportingCubit>().upsertEntry(
      day,
      ReportedEntry(
        id: 'r$i',
        eventId: 'p$i',
        title: 'Report $i',
        start: start,
        end: start.add(const Duration(hours: 1)),
        status: ReportStatus.attended,
        auto: false,
      ),
    );
  }
  await tester.pumpAndSettle();
  await tester.tap(find.text('Plan + Report'));
  await tester.pumpAndSettle();
  final tile = find.byKey(const ValueKey('tile:p0'));
  final scroll = Scrollable.maybeOf(tester.element(tile))!.position;
  final minutes = (24 - startHour) * 60;
  final scale = (scroll.maxScrollExtent + scroll.viewportDimension) / minutes;
  scroll.jumpTo((8 - startHour) * 60 * scale - 60);
  await tester.pumpAndSettle();
  final chip = find.byWidgetPredicate(
    (w) => w is ReportChip && w.block.entryId == 'r0',
  );
  void aligned() {
    for (var i = 0; i < 2; i++) {
      final report = find.byWidgetPredicate(
        (w) => w is ReportChip && w.block.entryId == 'r$i',
      );
      expect(
        tester.getTopLeft(report).dy,
        closeTo(tester.getTopLeft(find.byKey(ValueKey('tile:p$i'))).dy, 2),
      );
    }
  }

  aligned();
  if (golden != null) {
    await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden));
  }
  final before = tester.getTopLeft(tile).dy;
  tester.binding.handlePointerEvent(
    PointerScrollEvent(
      position: tester.getCenter(chip),
      scrollDelta: const Offset(0, 30),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.getTopLeft(tile).dy, closeTo(before - 30, 1));
  aligned();
  final offset = scroll.pixels;
  await tester.drag(chip, const Offset(0, -25));
  await tester.pumpAndSettle();
  expect(scroll.pixels, greaterThan(offset));
  aligned();
  scroll.jumpTo(offset);
  await tester.pumpAndSettle();
  await tester.tap(chip);
  await tester.pumpAndSettle();
  expect(find.text('Event details'), findsOneWidget);
  expect(find.textContaining('8:00 AM'), findsWidgets);
  expect(tester.takeException(), isNull);
}
