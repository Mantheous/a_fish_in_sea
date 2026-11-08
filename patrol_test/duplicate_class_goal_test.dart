import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/auto_goal.dart';
import 'package:a_fish_in_sea/nodes/view/nodes_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  patrolTest('Duplicating a finished class keeps the original complete', (
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
          'patrol-class-copy-${now.microsecondsSinceEpoch}@example.com',
        );
    await $(TextField).at(1).enterText('patrol-pass-1');
    await $('Create account').tap();
    await $.pumpAndSettle();
    await $(Icons.menu).tap();
    await $('Goals').tap();
    await $.pumpAndSettle();

    final nodes = $.tester.element(find.byType(NodesPage)).read<NodeCubit>();
    final originalClass = Node(
      id: 'class',
      title: 'Literature',
      createdAt: now,
      classFacet: const ClassFacet(),
      auto: const AutoFacet(metric: AutoMetric.allDone),
    );
    final task = Node(
      id: 'essay',
      title: 'Essay',
      createdAt: now,
      parentIds: const ['class'],
      classNodeId: 'class',
      status: NodeStatus.done,
      completedAt: now,
    );
    nodes.addNode(originalClass);
    nodes.addNode(task);
    await $('Goal tree').tap();
    await $.pumpAndSettle();
    expect($(find.byTooltip('Class complete — all work done')).visible, isTrue);

    final row = find.ancestor(
      of: find.text('Literature'),
      matching: find.byType(ListTile),
    );
    await $.tester.tap(
      find.descendant(of: row, matching: find.byIcon(Icons.more_vert)),
    );
    await $.pumpAndSettle();
    await $('Duplicate subtree').tap();
    await $.pumpAndSettle();

    expect($('Literature (copy)').visible, isTrue);
    final copy = nodes.state.singleWhere((n) => n.title == 'Literature (copy)');
    final copiedTask = nodes.state.singleWhere(
      (n) => n.parentIds.contains(copy.id),
    );
    expect(copiedTask.classNodeId, copy.id);
    expect(copiedTask.isOpen, isTrue);
    final reading = evaluateAutoGoal(
      originalClass,
      now: now,
      nodes: nodes.state,
    );
    expect(reading.totalCount, 1);
    expect(reading.doneCount, 1);
    expect(reading.satisfied, isTrue);
    expect(nodes.byId('class'), originalClass);
    expect(nodes.byId('essay'), task);
    expect($(find.byTooltip('Class complete — all work done')).visible, isTrue);
    expect(
      $(find.byTooltip('Class — completes when all work is done')).visible,
      isTrue,
    );
    expect($.tester.takeException(), isNull);
  });
}
