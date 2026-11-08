import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

/// Shared by the golden and browser tests; operates on the real calendar.
Future<Finder> verifyDstCalendarDrag(
  WidgetTester tester,
  DateTime day, {
  required String view,
}) async {
  final context = tester.element(find.byType(CalendarPage));
  context.read<SettingsCubit>().setDayHours(8, 18);
  await tester.tap(find.text(view));
  await tester.pumpAndSettle();
  final controller = tester
      .widget<SfCalendar>(find.byType(SfCalendar))
      .controller!;
  controller.displayDate = day;
  controller.selectedDate = day;
  final calendar = context.read<CalendarCubit>();
  final start = DateTime(day.year, day.month, day.day, 9);
  final event = PlannerEvent(
    id: 'dst-${day.month}-$view',
    subject: 'Clock change appointment',
    start: start,
    end: start.add(const Duration(hours: 1)),
  );
  calendar.addEvent(event);
  await tester.pumpAndSettle();
  final bounds = tester.getRect(find.byType(SfCalendar));
  for (final state in tester.stateList<ScrollableState>(
    find.descendant(
      of: find.byType(SfCalendar),
      matching: find.byType(Scrollable),
    ),
  )) {
    if (state.position.axis == Axis.vertical &&
        bounds.contains(tester.getRect(find.byWidget(state.widget)).center)) {
      state.position.jumpTo(0);
    }
  }
  await tester.pumpAndSettle();
  final tile = find.byKey(ValueKey('tile:${event.id}'));
  final rect = tester.getRect(tile);
  final gesture = await tester.startGesture(
    Offset(rect.left + 10, rect.center.dy),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.moveBy(const Offset(30, 0));
  await tester.pump(const Duration(milliseconds: 16));
  expect(
    tester.widget<Opacity>(tile).opacity,
    0.35,
    reason: 'the pointer must actually start a drag',
  );
  await gesture.up();
  await tester.pumpAndSettle();
  expect(calendar.byId(event.id)!.start, start);
  expect(calendar.byId(event.id)!.end, event.end);
  expect(tester.getRect(tile).top, closeTo(rect.top, 1));
  expect(tester.takeException(), isNull);
  return tile;
}
