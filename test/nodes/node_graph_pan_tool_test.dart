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

/// Pan is the default tool on every screen size. Taps still select and edit a
/// single goal; the Select tool button switches empty-canvas drags to a
/// marquee.
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

  Future<void> pumpGraph(
    WidgetTester tester,
    NodeCubit nodes, {
    Size size = const Size(420, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await tester.tap(find.text('Graph'));
    await tester.pump();
  }

  testWidgets('pan is default, and taps still select and edit a goal', (
    tester,
  ) async {
    final nodes = NodeCubit();
    nodes.emitSilent([
      goal('root', title: 'Root goal'),
      goal('child', title: 'Child goal', parents: ['root']),
    ]);
    await pumpGraph(tester, nodes);

    final nav = tester.widget<NodeGraphNavControls>(
      find.byType(NodeGraphNavControls),
    );
    expect(nav.handTool, isTrue, reason: 'pan is the default tool');

    // A tap selects the card (and pans zero pixels).
    await tester.tap(find.byKey(const ValueKey('graph-node-root')));
    await tester.pump();
    expect(find.byKey(const ValueKey('graph-action-bar')), findsOneWidget);

    // A second tap opens the single-goal editor while still in pan mode.
    await tester.tap(find.byKey(const ValueKey('graph-node-root')));
    await tester.pumpAndSettle();
    expect(find.text('Edit node'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pan drags move the graph; Select restores marquee', (
    tester,
  ) async {
    final nodes = NodeCubit();
    nodes.emitSilent([
      goal('root', title: 'Root goal'),
      goal('child', title: 'Child goal', parents: ['root']),
    ]);
    await pumpGraph(tester, nodes);

    final rootFinder = find.byKey(const ValueKey('graph-node-root'));
    final before = tester.getTopLeft(rootFinder);
    final view = tester.getRect(find.byType(NodeGraphView));
    await tester.dragFrom(view.center, const Offset(50, 30));
    await tester.pump();
    final after = tester.getTopLeft(rootFinder);
    expect(after.dx - before.dx, closeTo(50, 1.5));
    expect(after.dy - before.dy, closeTo(30, 1.5));
    expect(find.byKey(nodeGraphMultiBarKey), findsNothing);

    // Switching to Select restores drag-to-marquee.
    await tester.tap(find.byKey(const ValueKey('graph-select-tool')));
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

  testWidgets('the wide graph also defaults to pan', (tester) async {
    final nodes = NodeCubit();
    nodes.emitSilent([
      goal('root', title: 'Root goal'),
      goal('child', title: 'Child goal', parents: ['root']),
    ]);
    await pumpGraph(tester, nodes, size: const Size(1200, 900));

    final nav = tester.widget<NodeGraphNavControls>(
      find.byType(NodeGraphNavControls),
    );
    expect(nav.handTool, isTrue);

    final rootFinder = find.byKey(const ValueKey('graph-node-root'));
    final before = tester.getTopLeft(rootFinder);
    final view = tester.getRect(find.byType(NodeGraphView));
    await tester.dragFrom(view.center, const Offset(40, 25));
    await tester.pump();
    final after = tester.getTopLeft(rootFinder);
    expect(after.dx - before.dx, closeTo(40, 1.5));
    expect(after.dy - before.dy, closeTo(25, 1.5));
    expect(find.byKey(nodeGraphMultiBarKey), findsNothing);

    await tester.tap(rootFinder);
    await tester.pump();
    expect(find.byKey(const ValueKey('graph-action-bar')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
