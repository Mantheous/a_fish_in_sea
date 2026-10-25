import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/nodes_page.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  Node goal(
    String id, {
    String? title,
    List<String> parents = const [],
    NodeRecurrence? recurrence,
    String? instanceOf,
  }) => Node(
    id: id,
    title: title ?? id,
    parentIds: parents,
    createdAt: DateTime(2026, 1, 1),
    recurrence: recurrence,
    instanceOfId: instanceOf,
  );

  List<Node> sample() => [
    goal('root', title: 'Root goal'),
    goal('child', title: 'Child goal', parents: ['root']),
    goal('grand', title: 'Grandchild goal', parents: ['child']),
    goal(
      'habit',
      title: 'Daily habit',
      recurrence: const NodeRecurrence(frequency: TimeScale.daily),
    ),
    goal(
      'habit-instance',
      title: 'Habit instance',
      parents: ['habit'],
      instanceOf: 'habit',
    ),
  ];

  Widget harness(NodeCubit nodes) => MultiBlocProvider(
    providers: [
      BlocProvider.value(value: nodes),
      BlocProvider(create: (_) => TransactionsCubit()),
      BlocProvider(create: (_) => CalendarCubit()),
      BlocProvider(create: (_) => UndoCubit()),
      BlocProvider(create: (_) => NavigationCubit()),
    ],
    child: const MaterialApp(home: NodesPage()),
  );

  Future<void> openGraph(WidgetTester tester) async {
    await tester.tap(find.text('Graph'));
    await tester.pump();
  }

  testWidgets('graph tab lays out goals and opens the editor on tap', (
    tester,
  ) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    expect(find.text('Root goal'), findsOneWidget);
    expect(find.text('Child goal'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('graph-node-root')));
    await tester.pumpAndSettle();
    expect(find.text('Edit node'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapse badge hides and restores a subtree', (tester) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    await tester.tap(find.byKey(const ValueKey('graph-toggle-root')));
    await tester.pump();
    expect(find.text('Child goal'), findsNothing);
    expect(find.text('Grandchild goal'), findsNothing);
    expect(find.text('Root goal'), findsOneWidget);
    expect(find.text('+2'), findsOneWidget, reason: 'hidden-count badge');

    await tester.tap(find.byKey(const ValueKey('graph-toggle-root')));
    await tester.pump();
    expect(find.text('Child goal'), findsOneWidget);
    expect(find.text('Grandchild goal'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('repeating templates start collapsed, expand-all reveals them', (
    tester,
  ) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    expect(find.text('Daily habit'), findsOneWidget);
    expect(find.text('Habit instance'), findsNothing);
    expect(find.text('+1'), findsOneWidget);

    await tester.tap(find.byTooltip('Expand all'));
    await tester.pump();
    expect(find.text('Habit instance'), findsOneWidget);

    // The same button now collapses every parent.
    await tester.tap(find.byTooltip('Collapse all'));
    await tester.pump();
    expect(find.text('Child goal'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search in graph view shows matches despite collapse', (
    tester,
  ) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    // Collapse the root first: search must still reach the grandchild.
    await tester.tap(find.byKey(const ValueKey('graph-toggle-root')));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'Grandchild');
    await tester.pump();
    expect(find.text('Grandchild goal'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('graph is the default view for goals', (tester) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();

    final graphChip = find.ancestor(
      of: find.text('Graph'),
      matching: find.byType(ChoiceChip),
    );
    expect(graphChip, findsOneWidget);
    expect(tester.widget<ChoiceChip>(graphChip).selected, isTrue);
    expect(find.byKey(const ValueKey('graph-node-root')), findsOneWidget);
  });

  testWidgets(
    'filter keeps matched goals and collapses filtered-out ancestors',
    (tester) async {
      final today = DateTime.now();
      final nodes = NodeCubit();
      nodes.emitSilent([
        goal('root', title: 'Root goal'),
        goal('mid', title: 'Middle goal', parents: ['root']),
        Node(
          id: 'leaf',
          title: 'Due today leaf',
          parentIds: const ['mid'],
          createdAt: DateTime(2026, 1, 1),
          schedule: ScheduleFacet(due: today),
        ),
        Node(
          id: 'sibling',
          title: 'Later sibling',
          parentIds: const ['root'],
          createdAt: DateTime(2026, 1, 1),
          schedule: ScheduleFacet(
            due: today.add(const Duration(days: 20)),
          ),
        ),
      ]);
      await tester.pumpWidget(harness(nodes));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('goal-filter-button')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('goal-filter-date-today')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('goal-filter-apply')));
      await tester.pumpAndSettle();

      // The match is a full card; its filtered-out ancestors stay on the
      // path as compact markers so the relationship is readable.
      expect(find.byKey(const ValueKey('graph-node-leaf')), findsOneWidget);
      expect(find.byKey(const ValueKey('graph-context-root')), findsOneWidget);
      expect(find.byKey(const ValueKey('graph-context-mid')), findsOneWidget);
      expect(find.byKey(const ValueKey('graph-node-sibling')), findsNothing);
      expect(
        find.byKey(const ValueKey('goal-filter-chip-date')),
        findsOneWidget,
      );
      expect(find.textContaining('1 of 4 goals'), findsOneWidget);

      // Clearing the condition restores every goal at full size.
      await tester.tap(find.byKey(const ValueKey('goal-filter-clear-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('graph-node-root')), findsOneWidget);
      expect(find.byKey(const ValueKey('graph-node-sibling')), findsOneWidget);
      expect(find.byKey(const ValueKey('graph-context-root')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('topic filter scopes the graph to one branch', (tester) async {
    final nodes = NodeCubit();
    nodes.emitSilent([
      goal('school', title: 'School'),
      goal('math', title: 'Math', parents: ['school']),
      goal('home', title: 'Home'),
      goal('chores', title: 'Chores', parents: ['home']),
    ]);
    await tester.pumpWidget(harness(nodes));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('goal-filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('goal-filter-topic-school')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('goal-filter-apply')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('graph-node-school')), findsOneWidget);
    expect(find.byKey(const ValueKey('graph-node-math')), findsOneWidget);
    expect(find.byKey(const ValueKey('graph-node-home')), findsNothing);
    expect(find.byKey(const ValueKey('graph-node-chores')), findsNothing);
    expect(find.textContaining('2 of 4 goals'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty filter result offers a way back', (tester) async {
    final nodes = NodeCubit();
    nodes.emitSilent([
      goal('school', title: 'School'),
      goal('math', title: 'Math', parents: ['school']),
    ]);
    await tester.pumpWidget(harness(nodes));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('goal-filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('goal-filter-kind-money')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('goal-filter-apply')));
    await tester.pumpAndSettle();

    expect(find.text('No goals match these filters.'), findsOneWidget);
    await tester.tap(find.text('Clear filters'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('graph-node-school')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
