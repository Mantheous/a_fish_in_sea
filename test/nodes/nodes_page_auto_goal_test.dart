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

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  testWidgets('automated goal tile shows its weekly reading and icon', (
    tester,
  ) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    final now = DateTime.now();
    final start = now.subtract(const Duration(hours: 2));
    nodes.emitSilent([
      Node(
        id: 'study',
        title: 'Scripture study',
        createdAt: now.subtract(const Duration(days: 30)),
        auto: const AutoFacet(target: 120),
      ),
      Node(
        id: 'session',
        title: 'Morning study',
        parentIds: const ['study'],
        createdAt: start,
        schedule: ScheduleFacet(start: start, end: now),
        actualStart: start,
        actualEnd: now,
      ),
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

    await tester.tap(find.text('Goal tree'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Scripture study'), findsOneWidget);
    expect(find.byIcon(Icons.auto_graph), findsOneWidget);
    expect(find.textContaining('2h / 2h'), findsOneWidget);
    expect(find.textContaining('this week'), findsOneWidget);
    expect(find.textContaining('1 task'), findsOneWidget);

    // A dedicated filter puts every automated goal on one tracking list.
    await tester.tap(find.text('Automated'));
    await tester.pump();
    expect(find.text('Scripture study'), findsOneWidget);
    expect(find.textContaining('2h / 2h'), findsOneWidget);
  });
}
