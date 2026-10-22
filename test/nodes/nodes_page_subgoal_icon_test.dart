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

  testWidgets('parent rows in All view expose the Add subgoal button',
      (tester) async {
    final nodes = NodeCubit();
    expect(
        nodes.addNode(Node(
          id: 'node:p',
          title: 'Parent',
          createdAt: DateTime(2026, 10, 11),
        )),
        isNull);
    expect(
        nodes.addNode(Node(
          id: 'node:c',
          title: 'Child',
          parentIds: const ['node:p'],
          createdAt: DateTime(2026, 10, 11),
        )),
        isNull);
    await tester.pumpWidget(harness(nodes));
    await tester.pump();

    // Parent goals render as expandable rows in the All view.
    await tester.tap(find.text('All'));
    await tester.pump();
    expect(find.text('Parent'), findsOneWidget);

    // Tapping the parent row itself opens the editor, not the children.
    await tester.tap(find.text('Parent'));
    await tester.pumpAndSettle();
    expect(find.text('Edit node'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Expand the parent via its chevron so the child leaf renders too.
    await tester.tap(find.byTooltip('Expand'));
    await tester.pumpAndSettle();

    // Both the parent header and the child leaf must offer Add subgoal
    // with a visible icon.
    expect(find.byTooltip('Add subgoal'), findsNWidgets(2));
    expect(find.byIcon(Icons.add_task_outlined), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('goal rows expose the overflow menu with an explicit icon',
      (tester) async {
    final nodes = NodeCubit();
    expect(
        nodes.addNode(Node(
          id: 'node:p',
          title: 'Parent',
          createdAt: DateTime(2026, 10, 11),
        )),
        isNull);
    expect(
        nodes.addNode(Node(
          id: 'node:c',
          title: 'Child',
          parentIds: const ['node:p'],
          createdAt: DateTime(2026, 10, 11),
        )),
        isNull);
    await tester.pumpWidget(harness(nodes));
    await tester.pump();

    // Parent goals render as expandable rows in the All view.
    await tester.tap(find.text('All'));
    await tester.pump();
    expect(find.text('Parent'), findsOneWidget);

    // The overflow menu must carry an explicit icon (not rely on the
    // PopupMenuButton default) so it stays visible even when the web
    // icon-font subset drops the default glyph (refs #32).
    final popups = find.byType(PopupMenuButton<String>);
    expect(popups, findsNWidgets(1));
    expect(
      find.descendant(
        of: popups,
        matching: find.byIcon(Icons.more_vert),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('More actions'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
