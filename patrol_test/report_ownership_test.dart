import 'dart:async';

import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/timer_edit_sheet.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/report_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  patrolTest('Adjust preserves identical recordings on unrelated goals', (
    $,
  ) async {
    // Stop the sign-in screen's repeating fish animation while settling.
    $.tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
      $.tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    await $.pumpWidgetAndSettle(const MyApp());
    final stamp = DateTime.now().microsecondsSinceEpoch;
    await $(TextField).at(0).enterText('patrol-report-$stamp@example.com');
    await $(TextField).at(1).enterText('patrol-pass-1');
    await $('Create account').tap();
    await $.pumpAndSettle();

    final context = $.tester.element(find.byType(HomePage));
    final nodes = context.read<NodeCubit>();
    final calendar = context.read<CalendarCubit>();
    context.read<SettingsCubit>().setDefaultCalendarView(CalendarView.day);
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day, 9);
    final end = start.add(const Duration(hours: 1));
    for (var i = 1; i <= 2; i++) {
      nodes.addNode(
        Node(
          id: 'n$i',
          title: 'Goal $i',
          createdAt: start,
          schedule: ScheduleFacet(start: start, end: end),
        ),
      );
      calendar.addEvent(
        PlannerEvent(
          id: 'e$i',
          subject: 'Goal $i',
          taskId: 'n$i',
          isTask: true,
          start: start,
          end: end,
        ),
      );
    }
    calendar.addEvent(
      PlannerEvent(
        id: 'sibling',
        subject: 'Goal 1 later',
        taskId: 'n1',
        isTask: true,
        start: start.add(const Duration(hours: 5)),
        end: end.add(const Duration(hours: 5)),
      ),
    );
    for (var i = 1; i <= 2; i++) {
      // Open the same sheet used by Adjust in the goal editor. Matching
      // planned ranges let both saves use precisely the same timestamps.
      unawaited(showEditNodeTimerSheet(context, nodeId: 'n$i'));
      await $.pumpAndSettle();
      await $('Save').tap();
      await $.pumpAndSettle();
      expect(nodes.byId('n$i')!.actualStart, start);
      expect(nodes.byId('n$i')!.actualEnd, end);
    }
    await $(Icons.menu).tap();
    await $.pumpAndSettle();
    await $('Calendar').tap();
    await $.pumpAndSettle();
    await $(Icons.fact_check).tap();
    await $.pumpAndSettle();

    final chips = $.tester.widgetList<ReportChip>(find.byType(ReportChip));
    expect(chips.map((c) => c.block.eventId), unorderedEquals(['e1', 'e2']));
    expect(
      chips.map((c) => c.block.title),
      unorderedEquals(['Goal 1', 'Goal 2']),
    );
    expect($.tester.takeException(), isNull);
  });
}
