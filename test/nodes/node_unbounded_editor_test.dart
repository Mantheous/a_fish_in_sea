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

Finder dialogTextField(String label) => find.descendant(
      of: find.byType(AlertDialog).first,
      matching: find.widgetWithText(TextField, label),
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

  testWidgets('editor creates an unbounded goal with no progress bar',
      (tester) async {
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
      'Serve others',
    );
    await tester.tap(find.widgetWithText(
        SwitchListTile, 'Abstract / unbounded goal'));
    await tester.pumpAndSettle();
    // Concrete sections hide while unbounded is on.
    final dialog = find.byType(AlertDialog);
    expect(
        find.descendant(of: dialog, matching: find.text('Schedule')),
        findsNothing);
    expect(
        find.descendant(of: dialog, matching: find.text('Money')),
        findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final saved = nodes.state.single;
    expect(saved.title, 'Serve others');
    expect(saved.isUnbounded, isTrue);
    // The page lands on the tree by itself: unbounded goals are not in
    // the default Leaves view, so staying there would read as failure.
    expect(find.text('unbounded'), findsOneWidget);
    expect(find.byIcon(Icons.all_inclusive), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('turning unbounded on a dated goal asks before clearing',
      (tester) async {
    final nodes = NodeCubit();
    expect(
        nodes.addNode(Node(
          id: 'node:dated',
          title: 'Dated',
          createdAt: DateTime(2026, 10, 11),
          schedule: ScheduleFacet(due: DateTime(2026, 10, 20)),
        )),
        isNull);
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Dated'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(
        SwitchListTile, 'Abstract / unbounded goal'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    // Confirm gate lists what will go.
    expect(find.text('Remove dates and targets?'), findsOneWidget);
    expect(
        find.textContaining('schedule', findRichText: true), findsWidgets);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove and save'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final saved = nodes.byId('node:dated')!;
    expect(saved.isUnbounded, isTrue);
    expect(saved.schedule, isNull);
    // Unbounded goals live in the tree, not the Leaves view.
    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await tester.pumpAndSettle();
    expect(find.text('unbounded'), findsOneWidget);
  });

  testWidgets('confirm cancel keeps the goal unchanged', (tester) async {
    final nodes = NodeCubit();
    expect(
        nodes.addNode(Node(
          id: 'node:dated',
          title: 'Dated',
          createdAt: DateTime(2026, 10, 11),
          schedule: ScheduleFacet(due: DateTime(2026, 10, 20)),
        )),
        isNull);
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Dated'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(
        SwitchListTile, 'Abstract / unbounded goal'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Remove dates and targets?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Keep editing'));
    await tester.pumpAndSettle();

    // Back in the editor, nothing saved.
    expect(find.text('Remove dates and targets?'), findsNothing);
    final kept = nodes.byId('node:dated')!;
    expect(kept.isUnbounded, isFalse);
    expect(kept.schedule?.due, DateTime(2026, 10, 20));
  });

  testWidgets('saving a goal preserves its calendar block and due',
      (tester) async {
    final nodes = NodeCubit();
    expect(
        nodes.addNode(Node(
          id: 'node:blocked',
          title: 'Blocked',
          createdAt: DateTime(2026, 10, 11),
          schedule: ScheduleFacet(
            due: DateTime(2026, 10, 20),
            start: DateTime(2026, 10, 12, 9),
            end: DateTime(2026, 10, 12, 10),
          ),
        )),
        isNull);
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Blocked'));
    await tester.pumpAndSettle();
    // Day-only editor: due date inline, calendar times via Schedule.
    final dialog = find.byType(AlertDialog);
    expect(
        find.descendant(of: dialog, matching: find.text('Calendar block')),
        findsNothing);
    expect(find.text('Schedule'), findsOneWidget);
    expect(find.text('Day'), findsNothing);
    expect(find.text('Time'), findsNothing);
    expect(find.textContaining('Schedule → Time'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final saved = nodes.byId('node:blocked')!;
    expect(saved.schedule?.due, DateTime(2026, 10, 20));
    expect(saved.schedule?.start, DateTime(2026, 10, 12, 9));
    expect(saved.schedule?.end, DateTime(2026, 10, 12, 10));
  });
}
