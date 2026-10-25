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

  Node node(String id, String title, {String? notes}) => Node(
        id: id,
        title: title,
        notes: notes,
        createdAt: DateTime(2026, 1, 1),
      );

  Future<void> pumpField(
    WidgetTester tester,
    NodeCubit nodes,
    ValueChanged<List<String>> onChanged,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      BlocProvider.value(
        value: nodes,
        child: MaterialApp(
          home: Scaffold(
            body: ParentsField(
              selected: const [],
              excludeId: null,
              onChanged: onChanged,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('add parent picker filters the candidate list by search', (
    tester,
  ) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    nodes.emitSilent([
      node('a', 'Chemistry 105'),
      node('b', 'Guitar practice'),
      node('c', 'Write thesis'),
      node('d', 'Chemistry lab writeup'),
    ]);
    List<String> picked = const [];
    await pumpField(tester, nodes, (next) => picked = next);

    await tester.tap(find.widgetWithText(ActionChip, 'Add parent'));
    await tester.pumpAndSettle();

    // The picker opens with every eligible node.
    expect(find.text('Chemistry 105'), findsOneWidget);
    expect(find.text('Guitar practice'), findsOneWidget);
    expect(find.text('Write thesis'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'chem');
    await tester.pumpAndSettle();

    expect(find.text('Chemistry 105'), findsOneWidget);
    expect(find.text('Chemistry lab writeup'), findsOneWidget);
    expect(find.text('Guitar practice'), findsNothing);
    expect(find.text('Write thesis'), findsNothing);

    await tester.tap(find.text('Chemistry lab writeup'));
    await tester.pumpAndSettle();

    expect(picked, ['d']);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('search matches notes as well as titles', (tester) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    nodes.emitSilent([
      node('a', 'Project X', notes: 'secret keyword'),
      node('b', 'Project Y'),
    ]);
    await pumpField(tester, nodes, (_) {});

    await tester.tap(find.widgetWithText(ActionChip, 'Add parent'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'secret');
    await tester.pumpAndSettle();

    expect(find.text('Project X'), findsOneWidget);
    expect(find.text('Project Y'), findsNothing);
  });

  testWidgets('an empty result says so instead of showing a blank list', (
    tester,
  ) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    nodes.emitSilent([node('a', 'Chemistry 105')]);
    await pumpField(tester, nodes, (_) {});

    await tester.tap(find.widgetWithText(ActionChip, 'Add parent'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();

    expect(find.text('No nodes match.'), findsOneWidget);
  });

  testWidgets('the node itself and its descendants stay out of the list', (
    tester,
  ) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    nodes.emitSilent([
      node('self', 'Self'),
      Node(
        id: 'kid',
        title: 'Child',
        parentIds: const ['self'],
        createdAt: DateTime(2026, 1, 1),
      ),
      node('other', 'Other goal'),
    ]);
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      BlocProvider.value(
        value: nodes,
        child: MaterialApp(
          home: Scaffold(
            body: ParentsField(
              selected: const [],
              excludeId: 'self',
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(ActionChip, 'Add parent'));
    await tester.pumpAndSettle();

    expect(find.text('Self'), findsNothing);
    expect(find.text('Child'), findsNothing);
    expect(find.text('Other goal'), findsOneWidget);
  });
}
