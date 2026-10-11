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

  testWidgets('due and scheduled tabs render', (tester) async {
    final nodes = NodeCubit();
    final day = DateTime(2026, 10, 12, 9);
    nodes.emitSilent([
      Node(
        id: 'due',
        title: 'Due node',
        createdAt: DateTime(2026, 9, 1),
        schedule: ScheduleFacet(due: day),
      ),
      Node(
        id: 'sched',
        title: 'Scheduled node',
        createdAt: DateTime(2026, 9, 1),
        schedule: ScheduleFacet(
            due: day, start: day, end: day.add(const Duration(hours: 1))),
      ),
    ]);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider.value(value: nodes),
        BlocProvider(create: (_) => TransactionsCubit()),
        BlocProvider(create: (_) => CalendarCubit()),
        BlocProvider(create: (_) => UndoCubit()),
      ],
      child: const MaterialApp(home: NodesPage()),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Due'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Due node'), findsOneWidget);
    await tester.tap(find.text('Scheduled'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Scheduled node'), findsOneWidget);
  });
}
