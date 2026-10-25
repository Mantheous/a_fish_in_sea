import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/goals_view_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/node_graph_action_bar.dart';
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

  Widget harness(NodeCubit nodes, {GoalsViewCubit? view}) => MultiBlocProvider(
    providers: [
      BlocProvider.value(value: nodes),
      BlocProvider.value(value: view ?? GoalsViewCubit()),
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

  testWidgets('graph tab lays out goals, tap selects, tap again edits', (
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
    await tester.pump();
    expect(
      find.byKey(nodeGraphActionBarKey),
      findsOneWidget,
      reason: 'the tapped card is selected and its actions appear',
    );
    expect(find.byKey(const ValueKey('graph-action-record')), findsOneWidget);
    expect(find.text('Edit node'), findsNothing);
    expect(tester.takeException(), isNull);

    // A second tap on the selected card opens the editor, as before.
    await tester.tap(find.byKey(const ValueKey('graph-node-root')));
    await tester.pumpAndSettle();
    expect(find.text('Edit node'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selected goal records time from the action bar', (
    tester,
  ) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    await tester.tap(find.byKey(const ValueKey('graph-node-root')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('graph-action-record')));
    await tester.pump();

    expect(nodes.byId('root')?.isTracking, isTrue);
    expect(
      find.byKey(const ValueKey('graph-action-stop')),
      findsOneWidget,
      reason: 'the record button becomes stop while the timer runs',
    );

    await tester.tap(find.byKey(const ValueKey('graph-action-stop')));
    await tester.pumpAndSettle();
    expect(nodes.byId('root')?.isTracking, isFalse);
    expect(find.text('Work session saved'), findsOneWidget);
  });

  testWidgets('closing the action bar clears the selection', (tester) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    await tester.tap(find.byKey(const ValueKey('graph-node-root')));
    await tester.pump();
    expect(find.byKey(nodeGraphActionBarKey), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('graph-action-close')));
    await tester.pump();
    expect(find.byKey(nodeGraphActionBarKey), findsNothing);
  });

  testWidgets('action bar fits a phone width without overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    await tester.tap(find.byKey(const ValueKey('graph-node-root')));
    await tester.pump();
    expect(find.byKey(nodeGraphActionBarKey), findsOneWidget);
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

  testWidgets('goals with more than five subgoals start collapsed', (
    tester,
  ) async {
    final nodes = NodeCubit();
    nodes.emitSilent([
      goal('wide', title: 'Wide goal'),
      for (var i = 1; i <= 6; i++)
        goal('wide-$i', title: 'Wide child $i', parents: ['wide']),
      goal('narrow', title: 'Narrow goal'),
      for (var i = 1; i <= 5; i++)
        goal('narrow-$i', title: 'Narrow child $i', parents: ['narrow']),
    ]);
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    expect(find.text('Wide goal'), findsOneWidget);
    expect(find.text('Wide child 1'), findsNothing);
    expect(find.text('+6'), findsOneWidget, reason: 'hidden-count badge');
    // Five subgoals is still readable, so that goal stays expanded.
    expect(find.text('Narrow child 1'), findsOneWidget);
    expect(find.text('Narrow child 5'), findsOneWidget);

    // The default is only a seed: expanding by hand reveals the children.
    await tester.tap(find.byKey(const ValueKey('graph-toggle-wide')));
    await tester.pump();
    expect(find.text('Wide child 1'), findsOneWidget);
    expect(find.text('Wide child 6'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('graph fold state survives leaving the page and coming back', (
    tester,
  ) async {
    final nodes = NodeCubit();
    nodes.emitSilent([
      goal('wide', title: 'Wide goal'),
      for (var i = 1; i <= 6; i++)
        goal('wide-$i', title: 'Wide child $i', parents: ['wide']),
    ]);
    final view = GoalsViewCubit();
    addTearDown(view.close);
    await tester.pumpWidget(harness(nodes, view: view));
    await tester.pump();
    await openGraph(tester);

    // The default fold is recorded for the next visit.
    expect(find.text('Wide child 1'), findsNothing);
    await tester.pump();
    expect(view.state.collapsedIds, contains('wide'));

    await tester.tap(find.byKey(const ValueKey('graph-toggle-wide')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Wide child 1'), findsOneWidget);
    expect(view.state.collapsedIds, isNot(contains('wide')));

    // Navigate to another tab: the page is replaced and its state disposed.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    await tester.pumpWidget(harness(nodes, view: view));
    await tester.pump();

    expect(
      find.text('Wide child 1'),
      findsOneWidget,
      reason: 'a manual expand survives the tab switch',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('search survives leaving the page and coming back', (
    tester,
  ) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    final view = GoalsViewCubit();
    addTearDown(view.close);
    await tester.pumpWidget(harness(nodes, view: view));
    await tester.pump();
    await openGraph(tester);

    await tester.enterText(find.byType(TextField).first, 'Grandchild');
    await tester.pump();
    expect(find.text('Grandchild goal'), findsOneWidget);
    // Plain search keeps matches + ancestors; unrelated branches drop out.
    expect(find.text('Daily habit'), findsNothing);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    await tester.pumpWidget(harness(nodes, view: view));
    await tester.pump();

    expect(find.text('Grandchild'), findsOneWidget, reason: 'query kept');
    expect(find.text('Grandchild goal'), findsOneWidget);
    expect(
      find.text('Daily habit'),
      findsNothing,
      reason: 'the search still restricts the graph',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('filter survives leaving the page and coming back', (
    tester,
  ) async {
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
        schedule: ScheduleFacet(due: today.add(const Duration(days: 20))),
      ),
    ]);
    final view = GoalsViewCubit();
    addTearDown(view.close);
    await tester.pumpWidget(harness(nodes, view: view));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('goal-filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('goal-filter-date-today')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('goal-filter-apply')));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 of 4 goals'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    await tester.pumpWidget(harness(nodes, view: view));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('graph-node-leaf')),
      findsOneWidget,
      reason: 'the filter still scopes the graph',
    );
    expect(find.byKey(const ValueKey('graph-node-sibling')), findsNothing);
    expect(find.textContaining('1 of 4 goals'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the selected goals view survives leaving the page', (
    tester,
  ) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    final view = GoalsViewCubit();
    addTearDown(view.close);
    await tester.pumpWidget(harness(nodes, view: view));
    await tester.pump();

    await tester.tap(find.text('Open list'));
    await tester.pump();
    final listChip = find.ancestor(
      of: find.text('Open list'),
      matching: find.byType(ChoiceChip),
    );
    expect(tester.widget<ChoiceChip>(listChip).selected, isTrue);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    await tester.pumpWidget(harness(nodes, view: view));
    await tester.pump();

    expect(tester.widget<ChoiceChip>(listChip).selected, isTrue);
    expect(find.byKey(const ValueKey('graph-node-root')), findsNothing);
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

  testWidgets('tree action buttons use down/up arrows, not a plus', (
    tester,
  ) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    final subgoal = find.byKey(const ValueKey('graph-add-subgoal-root'));
    final parent = find.byKey(const ValueKey('graph-add-parent-root'));
    expect(subgoal, findsOneWidget);
    expect(parent, findsOneWidget);
    expect(
      find.descendant(of: subgoal, matching: find.byIcon(Icons.arrow_downward)),
      findsOneWidget,
      reason: 'a plus would read as the collapsed-count badge',
    );
    expect(
      find.descendant(of: parent, matching: find.byIcon(Icons.arrow_upward)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: subgoal, matching: find.byIcon(Icons.add)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('card ↓ button creates a subgoal under that goal', (tester) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    await tester.tap(find.byKey(const ValueKey('graph-add-subgoal-root')));
    await tester.pumpAndSettle();
    expect(find.text('New node'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Title').first,
      'Fresh subgoal',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    final created = nodes.state.singleWhere((n) => n.title == 'Fresh subgoal');
    expect(created.parentIds, ['root']);
    // The new card must be visible immediately, not hidden under a
    // collapsed parent.
    expect(find.text('Fresh subgoal'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('card ↑ button creates a parent goal above that goal', (
    tester,
  ) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    await tester.tap(find.byKey(const ValueKey('graph-add-parent-child')));
    await tester.pumpAndSettle();
    expect(find.text('New node'), findsOneWidget);
    // The editor explains the adoption this action performs.
    expect(find.textContaining('becomes a parent of'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Title').first,
      'New parent goal',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    final parent = nodes.state.singleWhere((n) => n.title == 'New parent goal');
    expect(parent.parentIds, isEmpty);
    // Shared DAG: the child keeps its existing parent and gains the new one.
    expect(nodes.byId('child')?.parentIds, ['root', parent.id]);
    expect(find.text('New parent goal'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('generated instances get no add buttons', (tester) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    // Habit instances start collapsed; expand-all reveals the instance.
    await tester.tap(find.byTooltip('Expand all'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('graph-node-habit-instance')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('graph-add-subgoal-habit-instance')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('graph-add-parent-habit-instance')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
