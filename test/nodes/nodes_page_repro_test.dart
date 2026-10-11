import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
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

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  testWidgets('adding a node does not blank the page', (tester) async {
    final nodes = NodeCubit();
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    expect(find.text('No nodes yet'), findsOneWidget);

    // Simulate exactly what the editor saves for a plain node.
    expect(
        nodes.addNode(Node(
          id: 'node:1',
          title: 'My goal',
          createdAt: DateTime(2026, 10, 11),
        )),
        isNull);
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('My goal'), findsOneWidget);
  });

  testWidgets('full editor flow: FAB -> title -> Add', (tester) async {
    final nodes = NodeCubit();
    await tester.pumpWidget(harness(nodes));
    await tester.pump();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    // Scope to the editor dialog: the page's own search field is also a
    // TextField once nodes exist.
    await tester.enterText(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            )
            .first,
        'Via editor');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Via editor'), findsOneWidget);
  });

  testWidgets('add subgoal pre-fills the parent', (tester) async {
    final nodes = NodeCubit();
    expect(
        nodes.addNode(Node(
          id: 'node:p',
          title: 'Parent',
          createdAt: DateTime(2026, 10, 11),
        )),
        isNull);
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add subgoal'));
    await tester.pumpAndSettle();
    // Parent is already attached; no need to use the picker.
    expect(find.widgetWithText(Chip, 'Parent'), findsOneWidget);
    // Scope to the editor dialog: the page's search field is also a
    // TextField.
    await tester.enterText(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            )
            .first,
        'Child');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(nodes.byId('node:p'), isNotNull);
    final child =
        nodes.state.firstWhere((n) => n.title == 'Child');
    expect(child.parentIds, ['node:p']);
  });
}
