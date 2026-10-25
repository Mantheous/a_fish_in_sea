import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/parents_field.dart';
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

  Node node(
    String id,
    String title, {
    String? notes,
    List<String> parents = const [],
    String? instanceOf,
    NodeRecurrence? recurrence,
    DateTime? createdAt,
    DateTime? completedAt,
  }) => Node(
    id: id,
    title: title,
    notes: notes,
    parentIds: parents,
    instanceOfId: instanceOf,
    recurrence: recurrence,
    createdAt: createdAt ?? DateTime(2026, 1, 1),
    completedAt: completedAt,
  );

  Future<void> pumpField(
    WidgetTester tester,
    NodeCubit nodes, {
    List<String> selected = const [],
    String? excludeId,
    ValueChanged<List<String>>? onChanged,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      BlocProvider.value(
        value: nodes,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ParentsField(
                selected: selected,
                excludeId: excludeId,
                onChanged: onChanged ?? (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> expand(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(ActionChip, 'Add parent'));
    await tester.pumpAndSettle();
  }

  testWidgets('stays collapsed until Add parent is tapped', (tester) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    nodes.emitSilent([
      node('a', 'Chemistry 105'),
      node('b', 'Guitar practice'),
    ]);
    await pumpField(tester, nodes);

    // Collapsed: no dialog, no search box, no rows — just the add chip.
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Chemistry 105'), findsNothing);
    expect(find.widgetWithText(ActionChip, 'Add parent'), findsOneWidget);

    await expand(tester);

    expect(find.text('Chemistry 105'), findsOneWidget);
    expect(find.text('Guitar practice'), findsOneWidget);
  });

  testWidgets('recent goals are filtered by search', (tester) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    nodes.emitSilent([
      node('a', 'Chemistry 105'),
      node('b', 'Guitar practice'),
      node('c', 'Write thesis'),
      node('d', 'Chemistry lab writeup', notes: 'secret keyword'),
    ]);
    List<String> picked = const [];
    await pumpField(tester, nodes, onChanged: (next) => picked = next);

    await expand(tester);

    await tester.enterText(find.byType(TextField), 'chem');
    await tester.pumpAndSettle();

    expect(find.text('Chemistry 105'), findsOneWidget);
    expect(find.text('Chemistry lab writeup'), findsOneWidget);
    expect(find.text('Guitar practice'), findsNothing);
    expect(find.text('Write thesis'), findsNothing);

    await tester.tap(find.text('Chemistry lab writeup'));
    await tester.pumpAndSettle();

    expect(picked, ['d']);
  });

  testWidgets('closing the picker collapses it and clears the search', (
    tester,
  ) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    nodes.emitSilent([
      node('a', 'Chemistry 105'),
      node('b', 'Guitar practice'),
    ]);
    await pumpField(tester, nodes);

    await expand(tester);
    await tester.enterText(find.byType(TextField), 'chem');
    await tester.pumpAndSettle();
    expect(find.text('Guitar practice'), findsNothing);

    await tester.tap(find.byTooltip('Close parent search'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.widgetWithText(ActionChip, 'Add parent'), findsOneWidget);

    await expand(tester);
    // The old query is gone, so the recent list is back unfiltered.
    expect(find.text('Guitar practice'), findsOneWidget);
  });

  testWidgets('search matches notes as well as titles', (tester) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    nodes.emitSilent([
      node('a', 'Project X', notes: 'secret keyword'),
      node('b', 'Project Y'),
    ]);
    await pumpField(tester, nodes);
    await expand(tester);

    await tester.enterText(find.byType(TextField), 'secret');
    await tester.pumpAndSettle();

    expect(find.text('Project X'), findsOneWidget);
    expect(find.text('Project Y'), findsNothing);
  });

  testWidgets('goals sort by last added or touched activity', (tester) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    nodes.emitSilent([
      node('old', 'Old goal', createdAt: DateTime(2026, 1, 1)),
      node('new', 'New goal', createdAt: DateTime(2026, 5, 1)),
      node(
        'worked',
        'Worked goal',
        createdAt: DateTime(2026, 2, 1),
        completedAt: DateTime(2026, 6, 1),
      ),
    ]);
    await pumpField(tester, nodes);
    await expand(tester);

    double top(String title) => tester.getTopLeft(find.text(title)).dy;
    expect(top('Worked goal'), lessThan(top('New goal')));
    expect(top('New goal'), lessThan(top('Old goal')));
  });

  testWidgets('the list opens on the newest four and says how many are left', (
    tester,
  ) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    nodes.emitSilent([
      for (var i = 1; i <= 7; i++)
        node('g$i', 'Goal $i', createdAt: DateTime(2026, 1, i)),
    ]);
    await pumpField(tester, nodes);
    await expand(tester);

    expect(find.text('Goal 7'), findsOneWidget);
    expect(find.text('Goal 4'), findsOneWidget);
    expect(find.text('Goal 3'), findsNothing);
    expect(find.text('Goal 1'), findsNothing);
    expect(find.text('3 more — type to search.'), findsOneWidget);
  });

  testWidgets('a repeating goal shows once and picks the template', (
    tester,
  ) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    nodes.emitSilent([
      node(
        'temple',
        'Attend the temple',
        recurrence: const NodeRecurrence(frequency: TimeScale.weekly),
      ),
      for (var i = 0; i < 6; i++)
        node(
          'temple-occurrence-$i',
          'Attend the temple',
          parents: const ['temple'],
          instanceOf: 'temple',
          createdAt: DateTime(2026, 3, 1 + i),
        ),
    ]);
    List<String> picked = const [];
    await pumpField(tester, nodes, onChanged: (next) => picked = next);
    await expand(tester);

    // One row for the series, not one per generated occurrence.
    expect(find.text('Attend the temple'), findsOneWidget);
    expect(find.text('Repeats weekly · 6 occurrences'), findsOneWidget);

    await tester.tap(find.text('Attend the temple'));
    await tester.pumpAndSettle();

    expect(picked, ['temple']);
  });

  testWidgets('editing a generated occurrence locks the parent list', (
    tester,
  ) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    nodes.emitSilent([
      node(
        'temple',
        'Attend the temple',
        recurrence: const NodeRecurrence(frequency: TimeScale.weekly),
      ),
      node(
        'temple-occurrence',
        'Attend the temple',
        parents: const ['temple'],
        instanceOf: 'temple',
      ),
      node('other', 'Other goal'),
    ]);
    await pumpField(
      tester,
      nodes,
      selected: const ['temple'],
      excludeId: 'temple-occurrence',
    );

    expect(find.text('Attend the temple'), findsOneWidget);
    expect(find.textContaining('Generated occurrence'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.widgetWithText(ActionChip, 'Add parent'), findsNothing);
    expect(find.text('Other goal'), findsNothing);
  });

  testWidgets('an empty result says so instead of showing a blank list', (
    tester,
  ) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    nodes.emitSilent([node('a', 'Chemistry 105')]);
    await pumpField(tester, nodes);
    await expand(tester);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();

    expect(find.text('No goals match "zzz".'), findsOneWidget);
  });

  testWidgets('the node itself and its descendants stay out of the list', (
    tester,
  ) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    nodes.emitSilent([
      node('self', 'Self'),
      node('kid', 'Child', parents: const ['self']),
      node('other', 'Other goal'),
    ]);
    await pumpField(tester, nodes, excludeId: 'self');
    await expand(tester);

    expect(find.text('Self'), findsNothing);
    expect(find.text('Child'), findsNothing);
    expect(find.text('Other goal'), findsOneWidget);
  });
}
