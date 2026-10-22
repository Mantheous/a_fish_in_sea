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

/// refs #70: saving a node in the editor without changes must not delete
/// its calendar block (start/end/allDay).
void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  testWidgets('editor save keeps the stored calendar block', (tester) async {
    final nodes = NodeCubit();
    final undo = UndoCubit();
    final events = CalendarCubit();
    nodes.addNode(Node(
      id: 'node:blocked',
      title: 'Blocked task',
      createdAt: DateTime(2026, 10, 11),
      schedule: ScheduleFacet(
        due: DateTime(2026, 10, 14),
        start: DateTime(2026, 10, 12),
        end: DateTime(2026, 10, 15),
        allDay: true,
      ),
    ));
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
                existing: nodes.byId('node:blocked'),
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

    // Save without touching anything.
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final kept = nodes.byId('node:blocked')?.schedule;
    expect(kept?.due, DateTime(2026, 10, 14));
    expect(kept?.start, DateTime(2026, 10, 12));
    expect(kept?.end, DateTime(2026, 10, 15));
    expect(kept?.allDay, isTrue);
  });
}
