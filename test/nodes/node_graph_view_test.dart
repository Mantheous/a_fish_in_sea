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
}
