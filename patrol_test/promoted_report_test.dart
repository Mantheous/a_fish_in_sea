import 'dart:async';

import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/nodes/view/timer_edit_sheet.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  patrolTest('promoted recordings survive resize and task Adjust', ($) async {
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
    await $.pumpWidget(const MyApp());
    final stamp = DateTime.now().millisecondsSinceEpoch;
    await $(TextField).at(0).enterText('patrol-promoted-$stamp@example.com');
    await $(TextField).at(1).enterText('patrol-pass-1');
    await $('Create account').tap();
    await $.pumpAndSettle();
    await $(Icons.menu).tap();
    await $('Calendar').tap();
    await $.pumpAndSettle();

    final context = $.tester.element(find.byType(CalendarPage));
    final calendar = context.read<CalendarCubit>();
    final nodes = context.read<NodeCubit>();
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, 9);
    final end = start.add(const Duration(minutes: 45));
    // Reproduce a stopped recording predating the task, using real actions.
    calendar.addEvent(
      PlannerEvent(
        id: 'promoted',
        subject: 'Recorded before Task',
        start: start,
        end: end,
      ),
    );
    calendar.startTracking('promoted', now: start);
    calendar.stopTracking('promoted', now: end);
    NodeEventLink.markEventAsNode(calendar, nodes, 'promoted');
    expect(
      NodeEventLink.backingNodeFor(
        nodes,
        calendar,
        'promoted',
      )!.recordedSessions,
      isEmpty,
    );
    await $.pumpAndSettle();
    await $('Plan + Report').tap();
    await $.pumpAndSettle();
    final chip = find.byKey(
      const ValueKey('report-chip:report:timer:promoted'),
    );
    await $.tester.tap(chip);
    await $.pumpAndSettle();
    final before = $.tester.getRect(chip);
    final handle = find.byWidgetPredicate(
      (w) =>
          w is Semantics && w.properties.label == 'Drag to adjust report end',
    );
    await $.tester.drag(handle, const Offset(0, 40));
    await $.pumpAndSettle();
    final saved = calendar.byId('promoted')!.recordedSessions.single;
    expect(saved.start, start);
    expect(saved.end.isAfter(end), isTrue);
    expect($.tester.getRect(chip).height, greaterThan(before.height));
    expect(find.textContaining('Reported time updated'), findsOneWidget);

    // refs #260: the next recording belongs to the task. Adjusting it
    // must preserve the earlier event-only recording and both identities.
    final taskId = calendar.byId('promoted')!.taskId!;
    final secondStart = start.add(const Duration(hours: 2));
    final secondEnd = secondStart.add(const Duration(minutes: 20));
    NodeEventLink.startNodeTracking(nodes, calendar, taskId, now: secondStart);
    NodeEventLink.stopNodeTrackingAligned(
      nodes,
      calendar,
      taskId,
      now: secondEnd,
    );
    final second = nodes.byId(taskId)!.recordedSessions.single;
    unawaited(showEditNodeTimerSheet(context, nodeId: taskId));
    await $.pumpAndSettle();
    final endTime = find.ancestor(
      of: find.text('End time'),
      matching: find.byType(InkWell),
    );
    await $.tester.tap(endTime);
    await $.pumpAndSettle();
    await $(Icons.keyboard_outlined).tap();
    await $.pumpAndSettle();
    await $(TextField).at(1).enterText('35');
    await $('OK').tap();
    await $.pumpAndSettle();
    await $('Save').tap();
    await $.pumpAndSettle();
    final corrected = second.copyWith(
      end: secondStart.add(const Duration(minutes: 35)),
    );
    expect(nodes.byId(taskId)!.recordedSessions, [corrected]);
    expect(calendar.byId('promoted')!.recordedSessions, [saved, corrected]);
    expect($.tester.takeException(), isNull);
  });
}
