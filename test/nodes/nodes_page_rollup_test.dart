import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
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

final _day = DateTime(2026, 10, 12, 9);

Node _task(String id, {List<String> parents = const [], bool done = false}) =>
    Node(
      id: id,
      title: id,
      parentIds: parents,
      createdAt: _day,
      status: done ? NodeStatus.done : NodeStatus.open,
      completedAt: done ? _day : null,
      schedule: ScheduleFacet(due: _day),
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

  testWidgets('goal tree lands on goals and rolls plain tasks up', (
    tester,
  ) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    nodes.emitSilent([
      Node(id: 'school', title: 'School', createdAt: _day),
      _task('Read chapter 4', parents: const ['school']),
      _task('Problem set 2', parents: const ['school']),
      _task('Old quiz', parents: const ['school'], done: true),
      _task('Loose task A'),
      _task('Loose task B'),
    ]);

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider.value(value: nodes),
          BlocProvider(create: (_) => TransactionsCubit()),
          BlocProvider(create: (_) => CalendarCubit()),
          BlocProvider(create: (_) => UndoCubit()),
        ],
        child: const MaterialApp(home: NodesPage()),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    // The graph is the landing view; the list-shaped tree is still one
    // chip away for rollup-heavy reading.
    final graphChip = find.ancestor(
      of: find.text('Graph'),
      matching: find.byType(ChoiceChip),
    );
    expect(tester.widget<ChoiceChip>(graphChip).selected, isTrue);

    await tester.tap(find.text('Goal tree'));
    await tester.pump();

    // Goals are visible; a goal's task children are behind one rollup
    // row. Unparented leaves are top-level items and stay visible.
    expect(find.text('School'), findsOneWidget);
    expect(find.text('Read chapter 4'), findsNothing);
    expect(find.text('Loose task A'), findsOneWidget);

    await tester.tap(find.byTooltip('Expand'));
    await tester.pump();
    expect(find.text('2 open · 1 done'), findsOneWidget);

    // Expanding the parent's rollup reveals every task, so nothing is
    // lost from the goals menu.
    await tester.tap(find.text('Tasks').first);
    await tester.pump();
    expect(find.text('Read chapter 4'), findsOneWidget);
    expect(find.text('Problem set 2'), findsOneWidget);
    expect(find.text('Old quiz'), findsOneWidget);
  });

  testWidgets('Open list still shows every leaf individually', (tester) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    nodes.emitSilent([
      Node(id: 'school', title: 'School', createdAt: _day),
      _task('Read chapter 4', parents: const ['school']),
      _task('Loose task A'),
    ]);

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider.value(value: nodes),
          BlocProvider(create: (_) => TransactionsCubit()),
          BlocProvider(create: (_) => CalendarCubit()),
          BlocProvider(create: (_) => UndoCubit()),
        ],
        child: const MaterialApp(home: NodesPage()),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Open list'));
    await tester.pump();

    expect(find.text('Read chapter 4'), findsOneWidget);
    expect(find.text('Loose task A'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
