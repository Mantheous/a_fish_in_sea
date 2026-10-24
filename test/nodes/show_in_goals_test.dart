import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/node_tile.dart';
import 'package:a_fish_in_sea/nodes/view/nodes_page.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

/// Parent goal with one nested child task — the shape "Show in goals"
/// is built for: the child is invisible in the All tree until its
/// parent is expanded.
NodeCubit seededNodes() {
  final nodes = NodeCubit();
  expect(
    nodes.addNode(
      Node(
        id: 'node:p',
        title: 'Parent goal',
        createdAt: DateTime(2026, 10, 11),
      ),
    ),
    isNull,
  );
  expect(
    nodes.addNode(
      Node(
        id: 'node:c',
        title: 'Child task',
        parentIds: const ['node:p'],
        createdAt: DateTime(2026, 10, 11),
      ),
    ),
    isNull,
  );
  return nodes;
}

Widget nodesHarness(NodeCubit nodes, NavigationCubit nav) =>
    MultiBlocProvider(
      providers: [
        BlocProvider.value(value: nodes),
        BlocProvider.value(value: nav),
        BlocProvider(create: (_) => TransactionsCubit()),
        BlocProvider(create: (_) => CalendarCubit()),
        BlocProvider(create: (_) => UndoCubit()),
      ],
      child: const MaterialApp(home: NodesPage()),
    );

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  group('NavigationCubit show-in-goals focus', () {
    test('showNodeInGoals opens Nodes with the target focused', () {
      final nav = NavigationCubit();
      nav.showNodeInGoals('node:c');
      expect(nav.state, PlannerPage.nodes);
      expect(nav.focusedNodeId, 'node:c');
    });

    test('refocusing while already on Nodes updates the target', () {
      final nav = NavigationCubit();
      nav.showNodeInGoals('node:a');
      final revision = nav.focusRevision.value;
      // The page emit is a duplicate and is suppressed — the revision
      // must still advance so NodesPage reacts.
      nav.showNodeInGoals('node:b');
      expect(nav.state, PlannerPage.nodes);
      expect(nav.focusedNodeId, 'node:b');
      expect(nav.focusRevision.value, isNot(equals(revision)));
    });

    test('manual navigation clears a pending focus', () {
      final nav = NavigationCubit();
      nav.showNodeInGoals('node:c');
      nav.setPage(PlannerPage.tasks);
      expect(nav.state, PlannerPage.tasks);
      expect(nav.focusedNodeId, isNull);
    });
  });

  testWidgets('task three-dots menu offers Show in goals', (tester) async {
    final nodes = seededNodes();
    final nav = NavigationCubit();
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider.value(value: nodes),
          BlocProvider.value(value: nav),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: NodeTile(
              node: nodes.byId('node:c')!,
              showClass: false,
              linkedEventIds: const {},
              linkedTaskIds: const {},
              upcomingEventCounts: const {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show in goals'));
    await tester.pumpAndSettle();
    expect(nav.state, PlannerPage.nodes);
    expect(nav.focusedNodeId, 'node:c');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'NodesPage reveals the focused task: All view, parent expanded, '
    'target highlighted',
    (tester) async {
      final nodes = seededNodes();
      final nav = NavigationCubit();
      await tester.pumpWidget(nodesHarness(nodes, nav));
      await tester.pump();

      // Baseline: in the All tree the child hides inside its collapsed
      // parent until something expands it.
      await tester.tap(find.text('Goal tree'));
      await tester.pump();
      expect(find.text('Parent goal'), findsOneWidget);
      expect(find.text('Child task'), findsNothing);

      // The request arrives while already on Nodes (emit suppressed) —
      // the focus revision alone must drive the reveal.
      nav.showNodeInGoals('node:c');
      await tester.pumpAndSettle();

      expect(find.text('Child task'), findsOneWidget);
      final theme = Theme.of(tester.element(find.text('Child task')));
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Material &&
              w.color == theme.colorScheme.secondaryContainer,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('focus set before first build lands on the All tree', (
    tester,
  ) async {
    final nodes = seededNodes();
    final nav = NavigationCubit();
    // Fresh navigation: the request precedes the page build.
    nav.showNodeInGoals('node:c');
    await tester.pumpWidget(nodesHarness(nodes, nav));
    await tester.pumpAndSettle();

    expect(find.text('Child task'), findsOneWidget);
    final allChip = find.ancestor(
      of: find.text('Goal tree'),
      matching: find.byType(ChoiceChip),
    );
    expect(allChip, findsOneWidget);
    expect(tester.widget<ChoiceChip>(allChip).selected, isTrue);
    expect(tester.takeException(), isNull);
  });
}
