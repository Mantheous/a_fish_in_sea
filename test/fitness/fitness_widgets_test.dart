import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/view/node_editor.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/settings/view/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

import '../goldens/golden_app.dart' as goldens;

/// Widget coverage for the fitness UI added for issue #30: the Workout
/// section in the node editor (the planner task path — tasks are Nodes,
/// created via showNodeEditor) and the Fitness watches card in Settings.
///
/// The full-screen goldens in test/goldens only capture above-the-fold
/// content, so the Settings card (bottom of a scrolling ListView) and the
/// editor section (inside a dialog scroll view) never appear in them —
/// these targeted widget tests pin them instead.
void main() {
  setUp(() {
    final storage = goldens.MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  testWidgets('node editor shows Workout section and fitness target fields',
      (tester) async {
    // Tall surface so the whole dialog fits without scrolling: the
    // Workout section sits below several other sections.
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final nodes = NodeCubit();
    final undo = UndoCubit();
    final events = CalendarCubit();
    addTearDown(() async {
      await nodes.close();
      await undo.close();
      await events.close();
    });

    await tester.pumpWidget(
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
                onPressed: () => showNodeEditor(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('New node'), findsOneWidget);

    expect(find.text('Workout & fitness'), findsOneWidget);
    expect(find.text('Workout'), findsOneWidget);
    expect(find.text('Has fitness target'), findsOneWidget);

    // Enabling the fitness target reveals the metric + value fields.
    await tester.tap(find.text('Has fitness target'));
    await tester.pumpAndSettle();
    expect(find.text('Measures'), findsOneWidget);
    expect(find.text('Target minutes'), findsOneWidget);
  });

  testWidgets('settings shows the Fitness watches card', (tester) async {
    await goldens.pumpGoldenPage(tester, const SettingsPage());
    await tester.scrollUntilVisible(
      find.text('Fitness watches'),
      500,
    );
    await tester.pump();
    expect(find.text('Fitness watches'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Connect Strava'), findsOneWidget);
  });

  testWidgets('blank fitness target blocks save instead of persisting 0',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final nodes = NodeCubit();
    final undo = UndoCubit();
    final events = CalendarCubit();
    addTearDown(() async {
      await nodes.close();
      await undo.close();
      await events.close();
    });

    await tester.pumpWidget(
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
                onPressed: () => showNodeEditor(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Title'), 'Morning run');
    await tester.tap(find.text('Has fitness target'));
    await tester.pumpAndSettle();

    // Blank target: save must warn and keep the dialog open with no node.
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Please enter a positive fitness target'),
        findsOneWidget);
    expect(find.text('New node'), findsOneWidget);
    expect(nodes.state, isEmpty);

    // Valid target saves and closes.
    await tester.enterText(
        find.widgetWithText(TextField, 'Target minutes'), '30');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('New node'), findsNothing);
    expect(nodes.state, hasLength(1));
    expect(nodes.state.single.fitness?.targetValue, 30.0);
  });
}
