import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/goals_view_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/node_graph_card.dart';
import 'package:a_fish_in_sea/nodes/view/node_graph_multi_action_bar.dart';
import 'package:a_fish_in_sea/nodes/view/node_graph_view.dart';
import 'package:a_fish_in_sea/nodes/view/nodes_page.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  Node goal(String id, {String? title, List<String> parents = const []}) =>
      Node(
        id: id,
        title: title ?? id,
        parentIds: parents,
        createdAt: DateTime(2026, 1, 1),
      );

  List<Node> sample() => [
    goal('root', title: 'Root goal'),
    goal('child', title: 'Child goal', parents: ['root']),
    goal('grand', title: 'Grandchild goal', parents: ['child']),
    goal('extra', title: 'Extra goal'),
  ];

  Widget harness(NodeCubit nodes) => MultiBlocProvider(
    providers: [
      BlocProvider.value(value: nodes),
      BlocProvider(create: (_) => GoalsViewCubit()),
      BlocProvider(create: (_) => TransactionsCubit()),
      BlocProvider(create: (_) => CalendarCubit()),
      BlocProvider(create: (_) => UndoCubit()),
      BlocProvider(create: (_) => NavigationCubit()),
    ],
    child: const MaterialApp(home: NodesPage()),
  );

  Future<void> openGraph(WidgetTester tester) async {
    await tester.tap(find.text('Graph'));
    await tester.pump();
  }

  Future<void> ctrlClick(WidgetTester tester, Finder finder) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(finder);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testWidgets('ctrl-click adds a second goal and opens the bulk editor', (
    tester,
  ) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    await tester.tap(find.byKey(const ValueKey('graph-node-root')));
    await tester.pump();
    await ctrlClick(tester, find.byKey(const ValueKey('graph-node-child')));

    expect(find.byKey(nodeGraphMultiBarKey), findsOneWidget);
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('graph-multi-edit')));
    await tester.pumpAndSettle();
    expect(find.text('Edit 2 goals'), findsOneWidget);
    final title = tester.widget<TextField>(
      find.byKey(const ValueKey('bulk-title')),
    );
    expect(title.enabled, isFalse, reason: 'titles stay individual');

    await tester.tap(find.byKey(const ValueKey('bulk-notes-toggle')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('bulk-notes-field')),
      'Shared note',
    );
    await tester.tap(find.byKey(const ValueKey('bulk-apply')));
    await tester.pumpAndSettle();

    expect(nodes.byId('root')!.notes, 'Shared note');
    expect(nodes.byId('child')!.notes, 'Shared note');
    expect(nodes.byId('grand')!.notes, isNull);
    expect(find.byKey(nodeGraphMultiBarKey), findsNothing);
    expect(find.text('2 goals updated'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long-press enters tap-to-toggle multi-select', (tester) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    await tester.longPress(find.byKey(const ValueKey('graph-node-root')));
    await tester.pump();
    // Long-press selects one card; a plain tap now adds another instead of
    // replacing the selection.
    await tester.tap(find.byKey(const ValueKey('graph-node-child')));
    await tester.pump();

    expect(find.byKey(nodeGraphMultiBarKey), findsOneWidget);
    expect(find.text('2 selected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bulk mark done completes the whole selection', (tester) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    await tester.tap(find.byKey(const ValueKey('graph-node-root')));
    await tester.pump();
    await ctrlClick(tester, find.byKey(const ValueKey('graph-node-child')));
    await tester.tap(find.byKey(const ValueKey('graph-multi-done')));
    await tester.pump();

    expect(nodes.byId('root')!.isDone, isTrue);
    expect(nodes.byId('child')!.isDone, isTrue);
    expect(nodes.byId('grand')!.isDone, isFalse);
    expect(find.byKey(nodeGraphMultiBarKey), findsNothing);
    expect(find.text('2 goals marked done'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bulk delete removes the selection and confirms first', (
    tester,
  ) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    await tester.tap(find.byKey(const ValueKey('graph-node-root')));
    await tester.pump();
    await ctrlClick(tester, find.byKey(const ValueKey('graph-node-child')));
    await tester.tap(find.byKey(const ValueKey('graph-multi-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 goals?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(nodes.byId('root'), isNull);
    expect(nodes.byId('child'), isNull);
    // The grandchild lost its only remaining parent, so it cascades too.
    expect(nodes.byId('grand'), isNull);
    expect(nodes.byId('extra'), isNotNull);
    expect(find.text('3 goals deleted'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dragging empty canvas marquee-selects cards', (tester) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    final view = tester.getRect(find.byType(NodeGraphView));
    final root = tester.getRect(find.byKey(const ValueKey('graph-node-root')));
    final child = tester.getRect(
      find.byKey(const ValueKey('graph-node-child')),
    );
    final start = Offset(view.left + 8, view.bottom - 8);
    final end = Offset(
      root.right + 8,
      (root.top < child.top ? root.top : child.top) - 8,
    );
    await tester.dragFrom(start, end - start);
    await tester.pump();

    expect(find.byKey(nodeGraphMultiBarKey), findsOneWidget);
    expect(
      tester
          .widget<NodeGraphCard>(find.byKey(const ValueKey('graph-node-root')))
          .selected,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('space-drag pans instead of selecting', (tester) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    final rootFinder = find.byKey(const ValueKey('graph-node-root'));
    final before = tester.getTopLeft(rootFinder);
    final view = tester.getRect(find.byType(NodeGraphView));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.dragFrom(view.center, const Offset(60, 40));
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pump();

    final after = tester.getTopLeft(rootFinder);
    expect(after.dx - before.dx, closeTo(60, 1.5));
    expect(after.dy - before.dy, closeTo(40, 1.5));
    expect(find.byKey(nodeGraphMultiBarKey), findsNothing);
    expect(find.byKey(const ValueKey('graph-action-bar')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('zoom controls expose the Figma-style percentage menu', (
    tester,
  ) async {
    final nodes = NodeCubit();
    nodes.emitSilent(sample());
    await tester.pumpWidget(harness(nodes));
    await tester.pump();
    await openGraph(tester);

    await tester.tap(find.byKey(const ValueKey('graph-node-root')));
    await tester.pump();
    expect(find.byKey(const ValueKey('graph-action-bar')), findsOneWidget);

    final label = find.byKey(const ValueKey('graph-zoom-label'));
    expect(label, findsOneWidget);
    final before = tester.widget<Text>(label).data;
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump();
    expect(tester.widget<Text>(label).data, isNot(before));
    expect(
      find.byKey(const ValueKey('graph-action-bar')),
      findsOneWidget,
      reason: 'using the floating controls must not clear the selection',
    );
    expect(find.byKey(const ValueKey('graph-pan-tool')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
