import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/node_editor.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

/// The fixed-date toggle is gone from the goal editor: a due date is
/// edited inline and a stored fixed flag is preserved untouched.
void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  Future<void> openEditor(WidgetTester tester, NodeCubit nodes) async {
    final undo = UndoCubit();
    final events = CalendarCubit();
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider.value(value: nodes),
        BlocProvider.value(value: undo),
        BlocProvider.value(value: events),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showNodeEditor(
                context,
                existing: nodes.byId('node:fixed'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Edit node'), findsOneWidget);
  }

  testWidgets('editor has no fixed-date toggle and keeps the stored flag',
      (tester) async {
    final nodes = NodeCubit();
    nodes.addNode(Node(
      id: 'node:fixed',
      title: 'Fixed commitment',
      createdAt: DateTime(2026, 10, 11),
      schedule: ScheduleFacet(
        due: DateTime(2026, 10, 20),
        isFixed: true,
      ),
    ));

    await openEditor(tester, nodes);
    expect(find.text('Fixed date'), findsNothing);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final kept = nodes.byId('node:fixed')?.schedule;
    expect(kept?.due, DateTime(2026, 10, 20));
    expect(kept?.isFixed, isTrue);
  });
}
