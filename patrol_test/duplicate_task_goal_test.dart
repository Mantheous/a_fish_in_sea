import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/nodes_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  patrolTest('Duplicate keeps an unscheduled goal in the Tasks filter', (
    $,
  ) async {
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
    final now = DateTime.now();
    await $(TextField)
        .at(0)
        .enterText(
          'patrol-task-copy-${now.microsecondsSinceEpoch}@example.com',
        );
    await $(TextField).at(1).enterText('patrol-pass-1');
    await $('Create account').tap();
    await $.pumpAndSettle();
    await $(Icons.menu).tap();
    await $('Goals').tap();
    await $.pumpAndSettle();

    final context = $.tester.element(find.byType(NodesPage));
    final nodes = context.read<NodeCubit>();
    nodes.addNode(Node(id: 'task', title: 'Call plumber', createdAt: now));
    nodes.addNode(Node(id: 'note', title: 'Other idea', createdAt: now));
    await $('Goal tree').tap();
    await $.pumpAndSettle();

    Future<void> openMenu(String title) async {
      final row = find.ancestor(
        of: find.text(title),
        matching: find.byType(ListTile),
      );
      await $.tester.tap(
        find.descendant(of: row, matching: find.byIcon(Icons.more_vert)),
      );
      await $.pumpAndSettle();
    }

    await openMenu('Call plumber');
    await $('Edit').tap();
    await $.pumpAndSettle();
    await $('Task').tap();
    await $('Save').tap();
    await $.pumpAndSettle();
    expect(nodes.byId('task')!.taskFlag, isTrue);
    expect(nodes.byId('task')!.schedule, isNull);

    await openMenu('Call plumber');
    await $('Duplicate subtree').tap();
    await $.pumpAndSettle();
    expect($('Call plumber (copy)').visible, isTrue);
    final copy = nodes.state.singleWhere(
      (n) => n.title == 'Call plumber (copy)',
    );
    expect(copy.taskFlag, isTrue);
    expect(copy.schedule, isNull);

    await $(find.byTooltip('Filter goals')).tap();
    await $.pumpAndSettle();
    await $(find.byKey(const ValueKey('goal-filter-kind-task'))).tap();
    await $('Apply').tap();
    await $.pumpAndSettle();
    expect($('Call plumber').visible, isTrue);
    expect($('Call plumber (copy)').visible, isTrue);
    expect($('Other idea').visible, isFalse);

    await openMenu('Call plumber (copy)');
    await $('Edit').tap();
    await $.pumpAndSettle();
    final taskSwitch = $.tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Task'),
    );
    expect(taskSwitch.value, isTrue);
    expect($.tester.takeException(), isNull);
  });
}
