import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_visibility_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:a_fish_in_sea/planner/view/event_editor.dart';
import 'package:a_fish_in_sea/planner/view/tasks_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

class MockGoogleService extends Mock implements GoogleCalendarService {}

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  group('draftSeedFromNode', () {
    test('builds a 9am ghost on the due date', () {
      final due = DateTime(2026, 9, 10, 23, 59);
      final seed = draftSeedFromNode(
        Node(
          id: 'node:hw1',
          title: 'Problem set 5',
          notes: 'Chapter 3',
          createdAt: DateTime(2026),
          schedule: ScheduleFacet(due: due),
          sourceEventId: 'evt:x',
          classLabel: 'Physics',
        ),
      );
      expect(seed.id, calendarDraftEventId);
      expect(seed.subject, 'Problem set 5');
      expect(seed.notes, 'Chapter 3');
      expect(seed.classLabel, 'Physics');
      expect(seed.start, DateTime(2026, 9, 10, 9));
      expect(seed.end, DateTime(2026, 9, 10, 10));
    });

    test('falls back to today when the task has no due date', () {
      final now = DateTime(2026, 9, 5, 15, 30);
      final seed = draftSeedFromNode(
        Node(
            id: 'node:t1',
            title: 'Read me',
            createdAt: DateTime(2026)),
        now: now,
      );
      expect(seed.start, DateTime(2026, 9, 5, 9));
    });
  });

  group('CalendarDraftCubit', () {
    test('request/take/clear roundtrip', () {
      final cubit = CalendarDraftCubit();
      expect(cubit.state, isNull);
      final seed = draftSeedFromNode(
        Node(id: 'node:t1', title: 'Hi', createdAt: DateTime(2026)),
      );
      cubit.requestDraft(seed);
      expect(cubit.state?.subject, 'Hi');
      expect(cubit.takePending()?.subject, 'Hi');
      expect(cubit.state, isNull);
      cubit.requestDraft(seed);
      cubit.clear();
      expect(cubit.state, isNull);
    });
  });

  Future<void> pumpCalendar(
    WidgetTester tester, {
    required CalendarCubit calendarCubit,
    required FeedCubit feedCubit,
    required SettingsCubit settingsCubit,
    required CalendarDraftCubit draftCubit,
  }) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider(create: (_) => UndoCubit()),
          BlocProvider(create: (_) => NavigationCubit()),
          BlocProvider.value(value: settingsCubit),
          BlocProvider.value(value: calendarCubit),
          BlocProvider.value(value: draftCubit),
          BlocProvider(create: (_) => CalendarVisibilityCubit()),
          BlocProvider(create: (_) => NodeCubit()),
          BlocProvider.value(value: feedCubit),
        ],
        child: const MaterialApp(home: CalendarPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  FeedCubit buildFeedCubit(
    CalendarCubit calendarCubit,
    NodeCubit nodeCubit,
  ) =>
      FeedCubit(
        calendarCubit: calendarCubit,
        nodeCubit: nodeCubit,
        icalService: IcalService(),
        googleService: MockGoogleService(),
        proxyBase: () => '',
      );

  Future<void> tapDrawerAdd(WidgetTester tester) async {
    final addButton = find.widgetWithText(FilledButton, 'Add');
    await tester.ensureVisible(addButton);
    await tester.pumpAndSettle();
    await tester.tap(addButton);
  }

  testWidgets('pending homework draft opens a ghost, saves nothing until Add',
      (tester) async {
    final calendarCubit = CalendarCubit();
    final nodeCubit = NodeCubit();
    final settingsCubit = SettingsCubit();
    final draftCubit = CalendarDraftCubit();
    final feedCubit = buildFeedCubit(calendarCubit, nodeCubit);
    draftCubit.requestDraft(
      draftSeedFromNode(
        Node(
          id: 'node:hw1',
          title: 'Study physics',
          createdAt: DateTime.now(),
          schedule: ScheduleFacet(due: DateTime.now()),
          sourceEventId: 'evt:x',
          classLabel: 'Physics',
        ),
      ),
    );

    await pumpCalendar(
      tester,
      calendarCubit: calendarCubit,
      feedCubit: feedCubit,
      settingsCubit: settingsCubit,
      draftCubit: draftCubit,
    );

    expect(find.textContaining('Ghost preview'), findsOneWidget);
    expect(find.byIcon(Icons.edit_calendar), findsWidgets);
    expect(calendarCubit.state, isEmpty);

    await tapDrawerAdd(tester);
    await tester.pumpAndSettle();

    expect(calendarCubit.state, hasLength(1));
    expect(calendarCubit.state.first.subject, 'Study physics');
    expect(find.textContaining('Ghost preview'), findsNothing);
  });

  testWidgets('FAB shows a movable ghost without saving until Add',
      (tester) async {
    final calendarCubit = CalendarCubit();
    final nodeCubit = NodeCubit();
    final settingsCubit = SettingsCubit();
    final draftCubit = CalendarDraftCubit();
    final feedCubit = buildFeedCubit(calendarCubit, nodeCubit);

    await pumpCalendar(
      tester,
      calendarCubit: calendarCubit,
      feedCubit: feedCubit,
      settingsCubit: settingsCubit,
      draftCubit: draftCubit,
    );

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.textContaining('Ghost preview'), findsOneWidget);
    expect(calendarCubit.state, isEmpty);

    await tapDrawerAdd(tester);
    await tester.pump();
    expect(calendarCubit.state, isEmpty);
    expect(
      find.text('Please enter a title'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));

    await tester.enterText(find.byType(TextField).first, 'Homework block');
    await tester.pump();
    await tapDrawerAdd(tester);
    await tester.pumpAndSettle();

    expect(calendarCubit.state, hasLength(1));
    expect(calendarCubit.state.first.subject, 'Homework block');
    expect(find.textContaining('Ghost preview'), findsNothing);
  });

  testWidgets('homework add-to-calendar requests a draft and opens calendar',
      (tester) async {
    final calendarCubit = CalendarCubit();
    final nodeCubit = NodeCubit();
    final settingsCubit = SettingsCubit();
    final navigationCubit = NavigationCubit();
    final draftCubit = CalendarDraftCubit();
    final feedCubit = buildFeedCubit(calendarCubit, nodeCubit);
    nodeCubit.addNode(
      Node(
        id: 'node:hw1',
        title: 'Problem set 5',
        createdAt: DateTime(2026),
        schedule: ScheduleFacet(due: DateTime(2026, 9, 10, 23, 59)),
        sourceEventId: 'evt:x',
        classLabel: 'Physics',
      ),
    );

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider(create: (_) => UndoCubit()),
          BlocProvider.value(value: navigationCubit),
          BlocProvider.value(value: settingsCubit),
          BlocProvider.value(value: calendarCubit),
          BlocProvider.value(value: draftCubit),
          BlocProvider.value(value: nodeCubit),
          BlocProvider.value(value: feedCubit),
        ],
        child: const MaterialApp(home: TasksPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Homework'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add to calendar').first);
    await tester.pump();

    expect(draftCubit.state, isNotNull);
    expect(draftCubit.state!.subject, 'Problem set 5');
    expect(draftCubit.state!.id, calendarDraftEventId);
    expect(navigationCubit.state, PlannerPage.calendar);
    expect(calendarCubit.state, isEmpty);
  });

  group('scheduling an assignment', () {
    // The Canvas "AI Plan" report: scheduling an assignment from the
    // Tasks menu must leave it in the task list, showing the block the
    // user picked — not silently delete it or demote it to an event.

    Node homework({
      String id = 'node:hw1',
      String title = 'AI Plan',
      DateTime? due,
    }) =>
        Node(
          id: id,
          title: title,
          createdAt: DateTime(2026, 10, 1),
          schedule: ScheduleFacet(due: due ?? DateTime(2026, 10, 16, 15)),
          sourceEventId: 'evt:x',
          classId: 'feed:1',
          classLabel: 'C S 291 Fall 2026',
        );

    /// Pumps the calendar with the caller's node store wired in, so a
    /// draft seeded from a task can be asserted against that same store.
    Future<void> pumpSeededCalendar(
      WidgetTester tester, {
      required CalendarCubit calendarCubit,
      required NodeCubit nodeCubit,
      required FeedCubit feedCubit,
      required SettingsCubit settingsCubit,
      required CalendarDraftCubit draftCubit,
      required NavigationCubit navigationCubit,
    }) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider(create: (_) => UndoCubit()),
            BlocProvider.value(value: navigationCubit),
            BlocProvider.value(value: settingsCubit),
            BlocProvider.value(value: calendarCubit),
            BlocProvider.value(value: draftCubit),
            BlocProvider(create: (_) => CalendarVisibilityCubit()),
            BlocProvider.value(value: nodeCubit),
            BlocProvider.value(value: feedCubit),
          ],
          child: const MaterialApp(home: CalendarPage()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('keeps the assignment and marks it as a scheduled task',
        (tester) async {
      final calendarCubit = CalendarCubit();
      final nodeCubit = NodeCubit();
      final settingsCubit = SettingsCubit();
      final draftCubit = CalendarDraftCubit();
      final navigationCubit = NavigationCubit();
      final feedCubit = buildFeedCubit(calendarCubit, nodeCubit);
      nodeCubit.addNode(homework());
      draftCubit.requestDraft(draftSeedFromNode(nodeCubit.byId('node:hw1')!));

      await pumpSeededCalendar(
        tester,
        calendarCubit: calendarCubit,
        nodeCubit: nodeCubit,
        feedCubit: feedCubit,
        settingsCubit: settingsCubit,
        draftCubit: draftCubit,
        navigationCubit: navigationCubit,
      );

      await tapDrawerAdd(tester);
      await tester.pumpAndSettle();

      expect(calendarCubit.state, hasLength(1));
      final saved = calendarCubit.state.first;
      // Scheduled out of a task: the event is that task's plan.
      expect(saved.isTask, isTrue);
      expect(saved.taskId, 'node:hw1');
      // The assignment is still in the task list, showing the block the
      // user picked, and keeps the due date its class gave it.
      final node = nodeCubit.byId('node:hw1');
      expect(node, isNotNull);
      expect(node!.calendarEventId, saved.id);
      expect(node.schedule?.start, saved.start);
      expect(node.schedule?.end, saved.end);
      expect(node.schedule?.due, DateTime(2026, 10, 16, 15));
      // Scheduling sends the user back to the task they just scheduled.
      expect(navigationCubit.state, PlannerPage.tasks);
    });

    testWidgets('turning the Task switch off still keeps the assignment',
        (tester) async {
      final calendarCubit = CalendarCubit();
      final nodeCubit = NodeCubit();
      final settingsCubit = SettingsCubit();
      final draftCubit = CalendarDraftCubit();
      final navigationCubit = NavigationCubit();
      final feedCubit = buildFeedCubit(calendarCubit, nodeCubit);
      nodeCubit.addNode(homework());
      draftCubit.requestDraft(draftSeedFromNode(nodeCubit.byId('node:hw1')!));

      await pumpSeededCalendar(
        tester,
        calendarCubit: calendarCubit,
        nodeCubit: nodeCubit,
        feedCubit: feedCubit,
        settingsCubit: settingsCubit,
        draftCubit: draftCubit,
        navigationCubit: navigationCubit,
      );

      final taskSwitch = find.widgetWithText(SwitchListTile, 'Task');
      expect(tester.widget<SwitchListTile>(taskSwitch).value, isTrue);
      await tester.ensureVisible(taskSwitch);
      await tester.pumpAndSettle();
      await tester.tap(taskSwitch);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(taskSwitch).value, isFalse);

      await tapDrawerAdd(tester);
      await tester.pumpAndSettle();

      expect(calendarCubit.state, hasLength(1));
      expect(calendarCubit.state.first.isTask, isFalse);
      // An event the user saved as a plain calendar block must not take
      // the assignment down with it.
      final node = nodeCubit.byId('node:hw1');
      expect(node, isNotNull);
      expect(node!.schedule?.start, calendarCubit.state.first.start);
      expect(node.schedule?.end, calendarCubit.state.first.end);
      expect(node.schedule?.due, DateTime(2026, 10, 16, 15));
    });

    testWidgets('the Task switch starts off for a plain new event',
        (tester) async {
      final settingsCubit = SettingsCubit();
      final calendarCubit = CalendarCubit();
      final nodeCubit = NodeCubit();
      final feedCubit = buildFeedCubit(calendarCubit, nodeCubit);

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider.value(value: settingsCubit),
            BlocProvider.value(value: calendarCubit),
            BlocProvider.value(value: nodeCubit),
            BlocProvider.value(value: feedCubit),
          ],
          child: const MaterialApp(
            home: Scaffold(body: EventEditorForm()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<SwitchListTile>(
                find.widgetWithText(SwitchListTile, 'Task'))
            .value,
        isFalse,
      );
    });

    testWidgets('the Task switch starts on for an event seeded by a task',
        (tester) async {
      final settingsCubit = SettingsCubit();
      final calendarCubit = CalendarCubit();
      final nodeCubit = NodeCubit();
      final feedCubit = buildFeedCubit(calendarCubit, nodeCubit);
      final start = DateTime(2026, 10, 16, 9);

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider.value(value: settingsCubit),
            BlocProvider.value(value: calendarCubit),
            BlocProvider.value(value: nodeCubit),
            BlocProvider.value(value: feedCubit),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: EventEditorForm(
                initialDate: DateTime(2026, 10, 16),
                initialTime: TimeOfDay.fromDateTime(start),
                initialTaskId: 'node:hw1',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<SwitchListTile>(
                find.widgetWithText(SwitchListTile, 'Task'))
            .value,
        isTrue,
      );
    });
  });
}
