import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

Future<void> verifyImportedAssignment(
  WidgetTester tester, {
  bool golden = false,
}) async {
  final context = tester.element(find.byType(CalendarPage));
  context.read<SettingsCubit>().setDayHours(8, 18);
  await tester.tap(find.text('Day'));
  await tester.pumpAndSettle();
  final start = DateTime(2030, 1, 1, 9);
  final controller = tester
      .widget<SfCalendar>(find.byType(SfCalendar))
      .controller!;
  controller.displayDate = start;
  controller.selectedDate = start;
  context.read<FeedCubit>().addFeed(
    const Feed(id: 'canvas', name: 'Canvas', url: '', kind: FeedKind.canvas),
  );
  final calendar = context.read<CalendarCubit>();
  final event = PlannerEvent(
    id: 'canvas-assignment',
    subject: 'In-class Assignment: Family Food',
    start: start,
    end: start,
    feedId: 'canvas',
    sourceUid: 'assignment',
    isTask: true,
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
  final tile = find.byKey(const ValueKey('tile:canvas-assignment'));
  var rect = tester.getRect(tile);
  final gesture = await tester.startGesture(
    Offset(rect.left + 30, rect.center.dy),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveBy(const Offset(0, 65));
  await tester.pump(const Duration(milliseconds: 16));
  expect(tester.widget<Opacity>(tile).opacity, 0.35);
  await gesture.up();
  await tester.pumpAndSettle();
  final moved = calendar.byId(event.id)!;
  expect(moved.start.isAfter(start), isTrue);
  expect(moved.plannedDuration, const Duration(hours: 1));
  rect = tester.getRect(tile);
  await tester.tapAt(Offset(rect.left + 30, rect.center.dy));
  await tester.pumpAndSettle();
  final handle = find.bySemanticsLabel('Drag to change end time').last;
  await tester.drag(handle, const Offset(0, 40));
  await tester.pumpAndSettle();
  final resized = calendar.byId(event.id)!;
  expect(resized.end.isAfter(moved.end), isTrue);
  ScaffoldMessenger.of(context).clearSnackBars();
  await tester.pumpAndSettle();
  expect(find.text('Edit'), findsOneWidget);
  if (golden) {
    await expectLater(
      find.byType(CalendarPage),
      matchesGoldenFile('../goldens/imported_assignment.png'),
    );
  }
  await tester.ensureVisible(find.text('Edit'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Edit'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('Save'));
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
  expect(calendar.byId(event.id)!.start, resized.start);
  expect(calendar.byId(event.id)!.end, resized.end);
  expect(calendar.byId(event.id)!.feedId, 'canvas');
  expect(tester.takeException(), isNull);
}
