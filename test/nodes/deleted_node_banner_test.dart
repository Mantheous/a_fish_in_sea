import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/node_editor.dart';
import 'package:a_fish_in_sea/nodes/view/node_finish_sheet.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

Node _node(String id, String title) => Node(
      id: id,
      title: title,
      createdAt: DateTime(2026, 10, 11),
    );

/// Minimal host: a scaffold (for the SnackBar) plus a button that opens
/// the editor / finish sheet on demand.
Widget harness({
  required NodeCubit nodes,
  required UndoCubit undo,
  required CalendarCubit events,
  required void Function(BuildContext) onOpen,
}) =>
    MultiBlocProvider(
      providers: [
        BlocProvider.value(value: nodes),
        BlocProvider.value(value: undo),
        BlocProvider.value(value: events),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => onOpen(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
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

  testWidgets('editor delete: Undo works after the dialog pops',
      (tester) async {
    final nodes = NodeCubit();
    final undo = UndoCubit();
    final events = CalendarCubit();
    nodes.addNode(_node('node:1', 'Doomed'));
    await tester.pumpWidget(harness(
      nodes: nodes,
      undo: undo,
      events: events,
      onOpen: (context) =>
          showNodeEditor(context, existing: nodes.byId('node:1')),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Edit node'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    // Two frames: flush the tap + pop, then finish the exit animation
    // (well inside the 4s snackbar window).
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    // Dialog is gone, node is gone, snackbar is up.
    expect(find.text('Edit node'), findsNothing);
    expect(nodes.byId('node:1'), isNull);
    expect(find.text('Node deleted'), findsOneWidget);

    // Undo must restore the node — the dialog context used for the
    // SnackBar action is unmounted by now, so this used to throw.
    await tester.tap(find.text('Undo'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(nodes.byId('node:1')?.title, 'Doomed');
  });

  testWidgets('rapid deletes do not queue a lingering banner', (tester) async {
    final nodes = NodeCubit();
    final undo = UndoCubit();
    final events = CalendarCubit();
    nodes.addNode(_node('node:1', 'First'));
    nodes.addNode(_node('node:2', 'Second'));
    late BuildContext hostContext;
    await tester.pumpWidget(harness(
      nodes: nodes,
      undo: undo,
      events: events,
      onOpen: (context) => hostContext = context,
    ));
    await tester.tap(find.text('open'));
    await tester.pump();

    // Fixed pumps keep the fake clock exact: entrance (150ms) and dialog
    // exit (~1s) complete, while each 4s snackbar window is untouched.
    showNodeEditor(hostContext, existing: nodes.byId('node:1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    showNodeEditor(hostContext, existing: nodes.byId('node:2'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // One banner at a time: the second delete replaces the first.
    expect(find.text('Node deleted'), findsOneWidget);
    // And it clears on its own — nothing queued behind it. Dismissal lands
    // ~5.5s after the second delete (4s timeout + transitions). The timeout,
    // exit animation, and queue handoff each need their own frames, so step
    // the clock granularly: one giant pump starves the sequence (the banner
    // then looks stuck even when it isn't).
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.text('Node deleted'), findsNothing);
  });

  testWidgets('finish sheet for a deleted node can be dismissed',
      (tester) async {
    final nodes = NodeCubit();
    final undo = UndoCubit();
    final events = CalendarCubit();
    await tester.pumpWidget(harness(
      nodes: nodes,
      undo: undo,
      events: events,
      onOpen: (context) =>
          showNodeFinishSheet(context, nodeId: 'node:gone'),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('This node was deleted.'), findsOneWidget);

    // Must offer an explicit way out (no swipe on desktop/web).
    expect(find.text('Close'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('This node was deleted.'), findsNothing);
  });
}
