import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/node_editor.dart';
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

    await tester.tap(find.byType(FloatingActionButton));
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

    await tester.tap(find.byType(FloatingActionButton));
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
    final homework = nodes.state.firstWhere((n) => n.title == 'Homework');
    expect(cls.title, 'CMLIT 201');
    expect(cls.parentIds, contains(homework.id));
    expect(task.classNodeId, cls.id);
    expect(task.parentIds, contains(cls.id));
    expect(task.isHomework, isTrue);
    expect(task.classLabel, 'CMLIT 201');
  });

  testWidgets('saving a legacy classId-only node keeps its feed id',
      (tester) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    final now = DateTime(2026, 10, 25);
    final homework = Node(
      id: 'homework',
      title: 'Homework',
      createdAt: now,
    );
    final cls = Node(
      id: 'cmlit',
      title: 'CMLIT 201',
      parentIds: const ['homework'],
      createdAt: now,
      classFacet: const ClassFacet(),
      auto: const AutoFacet(metric: AutoMetric.allDone),
    );
    final legacy = Node(
      id: 'legacy',
      title: 'Syllabus assignment',
      parentIds: const ['cmlit'],
      createdAt: now,
      classId: 'feed:old-syllabus',
      classLabel: 'CMLIT 201',
    );
    nodes.emitSilent([homework, cls, legacy]);
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
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showNodeEditor(context, existing: legacy),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, 'Save');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final saved = nodes.byId('legacy')!;
    expect(saved.classNodeId, 'cmlit');
    expect(saved.classId, 'feed:old-syllabus');
    expect(saved.classLabel, 'CMLIT 201');
  });

  testWidgets('adding a class in the Parents picker assigns the class',
      (tester) async {
    final nodes = NodeCubit();
    addTearDown(nodes.close);
    final now = DateTime(2026, 10, 25);
    final homework = Node(
      id: 'homework',
      title: 'Homework',
      createdAt: now,
    );
    final cls = Node(
      id: 'cmlit',
      title: 'CMLIT 201',
      parentIds: const ['homework'],
      createdAt: now,
      classFacet: const ClassFacet(),
      auto: const AutoFacet(metric: AutoMetric.allDone),
    );
    final review = Node(
      id: 'review',
      title: 'Midterm review',
      createdAt: now,
    );
    nodes.emitSilent([homework, cls, review]);
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
    await tester.pump();

    await tester.tap(find.text('Midterm review'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add parent'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CMLIT 201').last);
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, 'Save');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final saved = nodes.byId('review')!;
    expect(saved.classNodeId, 'cmlit');
    expect(saved.classLabel, 'CMLIT 201');
    expect(saved.classId, 'cmlit');
    expect(saved.parentIds, contains('cmlit'));
    expect(saved.isHomework, isTrue);
  });
}
