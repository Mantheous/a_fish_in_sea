import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/goals_view_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/node_graph_card.dart';
import 'package:a_fish_in_sea/nodes/view/node_graph_multi_action_bar.dart';
import 'package:a_fish_in_sea/nodes/view/node_graph_nav_controls.dart';
import 'package:a_fish_in_sea/nodes/view/node_graph_view.dart';
import 'package:a_fish_in_sea/nodes/view/nodes_page.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

/// Small screens keep the touch graph but start with the hand tool selected,
/// so a one-finger drag pans. Taps must still select, and the usual
/// long-press multi-select stays available.
void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  Node goal(String id, {String? title, List<String> parents = const []}) =>
      Node(
        id: id,
        title: title ?? id,
        parentIds: parents,
        createdAt: DateTime(2026, 1, 1),
      );

  Widget harness(NodeCubit nodes) => MultiBlocProvider(
    providers: [
      BlocProvider.value(value: nodes),
      BlocProvider(create: (_) => GoalsViewCubit()),
      BlocProvider(create: (_) => TransactionsCubit()),
      BlocProvider(create: (_) => CalendarCubit()),
      BlocProvider(create: (_) => UndoCubit()),
      BlocProvider(create: (_) => NavigationCubit()),
    ],
    child: const MaterialApp(home: NodesPage()),
  );

  Future<void> pumpSmallGraph(WidgetTester tester, NodeCubit nodes) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await tester.tap(find.text('Graph'));
    await tester.pump();
  }

  testWidgets('small screens start with pan selected but still tap to select', (
    tester,
  ) async {
    final nodes = NodeCubit();
    nodes.emitSilent([
      goal('root', title: 'Root goal'),
      goal('child', title: 'Child goal', parents: ['root']),
    ]);
    await pumpSmallGraph(tester, nodes);

    final nav = tester.widget<NodeGraphNavControls>(
      find.byType(NodeGraphNavControls),
    );
    expect(nav.handTool, isTrue, reason: 'auto pan on a compact viewport');

    await tester.tap(find.byKey(const ValueKey('graph-node-root')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('graph-action-bar')),
      findsOneWidget,
      reason: 'auto pan must not absorb card taps',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('small-screen drag pans, and select tool restores marquee', (
    tester,
  ) async {
    final nodes = NodeCubit();
    nodes.emitSilent([
      goal('root', title: 'Root goal'),
      goal('child', title: 'Child goal', parents: ['root']),
    ]);
    await pumpSmallGraph(tester, nodes);

    final rootFinder = find.byKey(const ValueKey('graph-node-root'));
    final before = tester.getTopLeft(rootFinder);
    final view = tester.getRect(find.byType(NodeGraphView));
    await tester.dragFrom(view.center, const Offset(50, 30));
    await tester.pump();
    final after = tester.getTopLeft(rootFinder);
    expect(after.dx - before.dx, closeTo(50, 1.5));
    expect(after.dy - before.dy, closeTo(30, 1.5));
    expect(find.byKey(nodeGraphMultiBarKey), findsNothing);

    // Switching to the select tool restores drag-to-marquee.
    await tester.tap(find.byKey(const ValueKey('graph-pan-tool')));
    await tester.pump();
    final selectedNav = tester.widget<NodeGraphNavControls>(
      find.byType(NodeGraphNavControls),
    );
    expect(selectedNav.handTool, isFalse);

    final root = tester.getRect(rootFinder);
    final child = tester.getRect(
      find.byKey(const ValueKey('graph-node-child')),
    );
    final start = Offset(view.left + 8, view.top + 8);
    final end = Offset(
      root.right + 8,
      (root.bottom > child.bottom ? root.bottom : child.bottom) + 8,
    );
    await tester.dragFrom(start, end - start);
    await tester.pump();

    expect(find.byKey(nodeGraphMultiBarKey), findsOneWidget);
    expect(tester.widget<NodeGraphCard>(rootFinder).selected, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small-screen long-press still enters multi-select', (
    tester,
  ) async {
    final nodes = NodeCubit();
    nodes.emitSilent([
      goal('root', title: 'Root goal'),
      goal('child', title: 'Child goal', parents: ['root']),
    ]);
    await pumpSmallGraph(tester, nodes);

    await tester.longPress(find.byKey(const ValueKey('graph-node-root')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('graph-node-child')));
    await tester.pump();

    expect(find.byKey(nodeGraphMultiBarKey), findsOneWidget);
    expect(find.text('2 selected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
