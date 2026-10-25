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

  testWidgets('opening Goals creates Homework and a class per imported class', (
    tester,
  ) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    nodes.emitSilent([
      Node(
        id: 'cmlit-essay',
        title: 'CMLIT essay',
        createdAt: DateTime(2026, 10, 1),
        feedId: 'feed:ls',
        classId: 'feed:ls',
        classLabel: 'CMLIT 201',
        sourceEventId: 'event:1',
      ),
      Node(
        id: 'math-set',
        title: 'Math set',
        createdAt: DateTime(2026, 10, 1),
        feedId: 'feed:ls',
        classId: 'feed:ls',
        classLabel: 'MATH 290',
        sourceEventId: 'event:2',
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
    await tester.pump();

    final homework = nodes.state.where((n) => n.title == 'Homework').single;
    expect(homework.parentIds, isEmpty);
    final classes = nodes.state.where((n) => n.isClassNode).toList();
    expect(classes.map((n) => n.title).toSet(), {'CMLIT 201', 'MATH 290'});
    for (final cls in classes) {
      expect(cls.parentIds, contains(homework.id));
    }
    expect(find.text('Homework'), findsOneWidget);
    expect(find.text('CMLIT 201'), findsOneWidget);
    expect(find.text('MATH 290'), findsOneWidget);
  });
}
