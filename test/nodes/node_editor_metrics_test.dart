import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
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

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  testWidgets('editor saves a goal with a time metric from New node', (
    tester,
  ) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider.value(value: nodes),
          BlocProvider(create: (_) => TransactionsCubit()),
          BlocProvider(create: (_) => CalendarCubit()),
          BlocProvider(create: (_) => UndoCubit()),
        ],
        child: const MaterialApp(home: NodesPage()),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Title').first,
      'Scripture study',
    );

    final addMetric = find.text('Add metric');
    await tester.ensureVisible(addMetric);
    await tester.pumpAndSettle();
    await tester.tap(addMetric);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Minutes').last);
    await tester.pumpAndSettle();

    final target = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Target minutes',
    );
    expect(target, findsOneWidget);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.enterText(target, '420');
    await tester.pump();

    final save = find.widgetWithText(FilledButton, 'Add');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final saved = nodes.state.single;
    expect(saved.title, 'Scripture study');
    expect(saved.metrics, hasLength(1));
    expect(saved.auto, isNotNull);
    expect(saved.auto!.target, 420);
    expect(saved.auto!.source, AutoSource.tasks);
    expect(saved.auto!.period, TimeScale.weekly);
  });

  testWidgets('editor assigns a manual task to a new class', (tester) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    nodes.emitSilent([
      Node(id: 'homework', title: 'Homework', createdAt: DateTime(2026, 10, 1)),
    ]);
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider.value(value: nodes),
          BlocProvider(create: (_) => TransactionsCubit()),
          BlocProvider(create: (_) => CalendarCubit()),
          BlocProvider(create: (_) => UndoCubit()),
        ],
        child: const MaterialApp(home: NodesPage()),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Title').first,
      'Midterm review',
    );

    await tester.tap(find.byTooltip('Pick class'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'New class name'),
      'CMLIT 201',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    final save = find.widgetWithText(FilledButton, 'Add');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final task = nodes.state.firstWhere((n) => n.title == 'Midterm review');
    final cls = nodes.state.firstWhere((n) => n.isClassNode);
    expect(cls.title, 'CMLIT 201');
    expect(cls.parentIds, contains('homework'));
    expect(task.classNodeId, cls.id);
    expect(task.parentIds, contains(cls.id));
    expect(task.isHomework, isTrue);
    expect(task.classLabel, 'CMLIT 201');
  });
}
