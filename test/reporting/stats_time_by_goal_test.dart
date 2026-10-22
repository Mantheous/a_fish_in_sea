import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/reporting/view/stats_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../goldens/golden_app.dart';

/// The Toggl-style week view: a timer stopped on a calendar event lands
/// in the Stats "Time by goal" card under its linked goal.
void main() {
  DateTime mondayOfThisWeek() {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    return DateTime(monday.year, monday.month, monday.day);
  }

  Future<void> pumpStats(WidgetTester tester) async {
    await pumpGoldenPage(tester, const StatsPage());
    // The Time by goal card sits below several taller cards; pump on a
    // tall surface (like stats_page_test) so it is built and findable
    // without scrolling.
    tester.view.physicalSize = const Size(900, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('stopped event timer shows under its goal with week total',
      (tester) async {
    await pumpStats(tester);
    final nodes = BlocProvider.of<NodeCubit>(
      tester.element(find.byType(StatsPage)),
    );
    final calendar = BlocProvider.of<CalendarCubit>(
      tester.element(find.byType(StatsPage)),
    );
    final monday = mondayOfThisWeek();
    final start = monday.add(const Duration(days: 1, hours: 9));

    expect(
      nodes.addNode(Node(
        id: 'goal',
        title: 'Study goal',
        createdAt: monday,
      )),
      isNull,
    );
    expect(
      nodes.addNode(Node(
        id: 'task',
        title: 'Homework',
        parentIds: const ['goal'],
        createdAt: monday,
        calendarEventId: 'evt:1',
      )),
      isNull,
    );
    calendar.addEvent(PlannerEvent(
      id: 'evt:1',
      subject: 'Math HW',
      start: start,
      end: start.add(const Duration(hours: 1)),
      isTask: true,
      taskId: 'task',
      actualStart: start.add(const Duration(minutes: 5)),
      actualEnd: start.add(const Duration(minutes: 50)),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Time by goal'), findsOneWidget);
    expect(find.text('Week total 45m'), findsOneWidget);
    expect(find.text('Study goal'), findsOneWidget);
    expect(find.text('Math HW'), findsOneWidget);
  });

  testWidgets('empty week shows the no-tracked-time hint', (tester) async {
    await pumpStats(tester);
    expect(find.text('Time by goal'), findsOneWidget);
    expect(find.textContaining('No tracked time this week'), findsOneWidget);
  });
}
