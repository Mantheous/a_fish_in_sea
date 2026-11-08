import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/view/event_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import '../test/nodes/node_goal_link_fixtures.dart';

void main() {
  patrolTest('This + future assigns and removes only the selected calendar', (
    $,
  ) async {
    $.tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
      $.tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );
    installGoalLinkStorage();
    await $.pumpWidgetAndSettle(const MyApp());
    final stamp = DateTime.now().microsecondsSinceEpoch;
    await $(TextField).at(0).enterText('patrol-series-$stamp@example.com');
    await $(TextField).at(1).enterText('patrol-pass-1');
    await $('Create account').tap();
    await $(HomePage).waitUntilVisible();
    final context = $.tester.element(find.byType(HomePage));
    final nodes = context.read<NodeCubit>();
    final calendar = context.read<CalendarCubit>();
    nodes.addNode(goal('Series goal'));
    final start = DateTime.now().add(const Duration(days: 1));
    for (final feed in ['a', 'b']) {
      for (var i = 1; i <= 2; i++) {
        calendar.addEvent(
          event(
            'gcal:$feed:$i',
            feedId: feed,
            seriesId: 'shared',
            isTask: false,
            start: start.add(Duration(days: i)),
          ),
        );
      }
    }
    final otherEvents = calendar.state.where((e) => e.feedId == 'b').toList();
    final detail = showEventDetail(context, event: calendar.byId('gcal:a:1')!);
    await $.pumpAndSettle();
    await $.tester.ensureVisible(find.text('Assign to goal'));
    await $('Assign to goal').tap();
    await $('Series goal').tap();
    await $('This + future (2)').tap();
    await $.pumpAndSettle();
    for (var i = 1; i <= 2; i++) {
      expect(calendar.byId('gcal:a:$i')?.isTask, isTrue);
      expect(nodes.byId('gcal:a:$i')?.parentIds, contains('Series goal'));
      expect(nodes.byId('gcal:b:$i'), isNull);
    }
    expect(calendar.state.where((e) => e.feedId == 'b'), otherEvents);

    final chip = find.widgetWithText(Chip, 'Series goal');
    await $.tester.ensureVisible(chip);
    await $.tester.tap(
      find.descendant(of: chip, matching: find.byIcon(Icons.close)),
    );
    await $.pumpAndSettle();
    await $('This + future').tap();
    await $.pumpAndSettle();
    for (var i = 1; i <= 2; i++) {
      expect(
        nodes.byId('gcal:a:$i')?.parentIds,
        isNot(contains('Series goal')),
      );
      expect(nodes.byId('gcal:b:$i'), isNull);
    }
    expect(calendar.state.where((e) => e.feedId == 'b'), otherEvents);
    expect($.tester.takeException(), isNull);
    Navigator.of(context).pop();
    await $.pumpAndSettle();
    await detail;
  });
}
