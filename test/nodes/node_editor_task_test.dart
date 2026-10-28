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

Finder taskSwitch() => find.widgetWithText(SwitchListTile, 'Task');

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  testWidgets('new goal can be marked as a task from the editor', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final nodes = NodeCubit();
    await tester.pumpWidget(harness(nodes));
    await tester.pump();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          )
          .first,
      'Read the manual',
    );
    final toggle = taskSwitch();
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: toggle, matching: find.text('Task')));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final saved = nodes.state.single;
    expect(saved.taskFlag, isTrue);
    expect(saved.isTask, isTrue);
  });

  testWidgets('a goal with a facet can become a task', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final nodes = NodeCubit();
    nodes.addNode(
      Node(
        id: 'node:budget',
        title: 'Food budget',
        createdAt: DateTime(2026, 10, 1),
        money: const MoneyFacet(targetAmount: 400, period: TimeScale.monthly),
      ),
    );
    await tester.pumpWidget(harness(nodes));
    await tester.pump();

    // First tap selects the card; the action bar's edit button opens the
    // editor (single-tap-to-edit went away with the pan-default graph).
    await tester.tap(find.byKey(const ValueKey('graph-node-node:budget')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('graph-action-edit')));
    await tester.pumpAndSettle();
    final toggle = taskSwitch();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: toggle, matching: find.text('Task')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final saved = nodes.byId('node:budget')!;
    expect(saved.taskFlag, isTrue);
    expect(saved.isTask, isTrue);
    expect(saved.money, isNotNull, reason: 'classification keeps the facet');
  });

  testWidgets('a scheduled leaf can opt out of task classification', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final nodes = NodeCubit();
    nodes.addNode(
      Node(
        id: 'node:leaf',
        title: 'Essay',
        createdAt: DateTime(2026, 10, 1),
        schedule: ScheduleFacet(due: DateTime(2026, 10, 20)),
      ),
    );
    await tester.pumpWidget(harness(nodes));
    await tester.pump();

    // First tap selects the card; the action bar's edit button opens the
    // editor (single-tap-to-edit went away with the pan-default graph).
    await tester.tap(find.byKey(const ValueKey('graph-node-node:leaf')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('graph-action-edit')));
    await tester.pumpAndSettle();
    final toggle = taskSwitch();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: toggle, matching: find.text('Task')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final saved = nodes.byId('node:leaf')!;
    expect(saved.taskFlag, isFalse);
    expect(saved.isTask, isFalse);
    expect(saved.schedule?.due, DateTime(2026, 10, 20));
  });
}
