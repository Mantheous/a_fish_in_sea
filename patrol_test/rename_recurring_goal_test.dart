import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/node_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import '../test/nodes/node_goal_link_fixtures.dart';

void main() {
  patrolTest('Renaming a custom recurring goal keeps its 14-day interval', (
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
    await $(TextField).at(0).enterText('patrol-recurrence-$stamp@example.com');
    await $(TextField).at(1).enterText('patrol-pass-1');
    await $('Create account').tap();
    await $(HomePage).waitUntilVisible();
    final context = $.tester.element(find.byType(HomePage));
    final nodes = context.read<NodeCubit>();
    final original = Node(
      id: 'payment',
      title: 'Payment',
      createdAt: DateTime(2026, 11, 2),
      recurrence: const NodeRecurrence(
        frequency: TimeScale.custom,
        customPeriodDays: 14,
        dayOfWeek: DateTime.friday,
        dayOfMonth: 23,
      ),
    );
    expect(nodes.addNode(original), isNull);
    final editing = showNodeEditor(context, existing: original);
    await $.pumpAndSettle();
    await $(
      find.widgetWithText(TextField, 'Title'),
    ).enterText('Renamed payment');
    await $('Save').tap();
    await $.pumpAndSettle();
    expect((await editing)?.title, 'Renamed payment');
    final restored = Node.fromJson(nodes.byId(original.id)!.toJson());
    expect(restored.recurrence, original.recurrence);
    expect(nodes.updateNode(restored), isNull);
    nodes.generateInstances(
      templateId: original.id,
      from: DateTime(2027, 1, 2),
      horizon: DateTime(2027, 1, 31),
    );
    expect(nodes.instancesOf(original.id).map((n) => n.schedule?.due), [
      DateTime(2027, 1, 2),
      DateTime(2027, 1, 16),
      DateTime(2027, 1, 30),
    ]);
    expect($.tester.takeException(), isNull);
  });
}
