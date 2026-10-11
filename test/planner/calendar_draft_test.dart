import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_visibility_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
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
    NavigationCubit? navigationCubit,
    NodeCubit? nodeCubit,
  }) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider(create: (_) => UndoCubit()),
          navigationCubit == null
              ? BlocProvider(create: (_) => NavigationCubit())
              : BlocProvider.value(value: navigationCubit),
          BlocProvider.value(value: settingsCubit),
          BlocProvider.value(value: calendarCubit),
          BlocProvider.value(value: draftCubit),
          BlocProvider(create: (_) => CalendarVisibilityCubit()),
          nodeCubit == null
              ? BlocProvider(create: (_) => NodeCubit())
              : BlocProvider.value(value: nodeCubit),
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

  testWidgets('saving a task-seeded draft returns to the task menu',
      (tester) async {
    final calendarCubit = CalendarCubit();
    final nodeCubit = NodeCubit();
    final settingsCubit = SettingsCubit();
    final draftCubit = CalendarDraftCubit();
    final navigationCubit = NavigationCubit();
    final feedCubit = buildFeedCubit(calendarCubit, nodeCubit);
    final node = Node(
      id: 'node:hw1',
      title: 'Study physics',
      createdAt: DateTime.now(),
      schedule: ScheduleFacet(due: DateTime.now()),
      sourceEventId: 'evt:x',
      classLabel: 'Physics',
    );
    nodeCubit.addNode(node);
    draftCubit.requestDraft(draftSeedFromNode(node));

    await pumpCalendar(
      tester,
      calendarCubit: calendarCubit,
      feedCubit: feedCubit,
      settingsCubit: settingsCubit,
      draftCubit: draftCubit,
      navigationCubit: navigationCubit,
      nodeCubit: nodeCubit,
    );

    await tapDrawerAdd(tester);
    await tester.pumpAndSettle();

    expect(calendarCubit.state, hasLength(1));
    // The next assignment can be scheduled without clicking around.
    expect(navigationCubit.state, PlannerPage.tasks);
    // And the task that lent the event its seed must still be in the list
    // (scheduling it must never delete the assignment).
    expect(nodeCubit.byId('node:hw1'), isNotNull);
    expect(nodeCubit.byId('node:hw1')!.calendarEventId,
        calendarCubit.state.first.id);
  });

  testWidgets('cancelling a task-seeded draft stays on the calendar',
      (tester) async {
    final calendarCubit = CalendarCubit();
    final nodeCubit = NodeCubit();
    final settingsCubit = SettingsCubit();
    final draftCubit = CalendarDraftCubit();
    final navigationCubit = NavigationCubit();
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
      navigationCubit: navigationCubit,
      nodeCubit: nodeCubit,
    );

    final cancelButton = find.widgetWithText(TextButton, 'Cancel');
    await tester.ensureVisible(cancelButton);
    await tester.pumpAndSettle();
    await tester.tap(cancelButton);
    await tester.pumpAndSettle();

    expect(calendarCubit.state, isEmpty);
    expect(navigationCubit.state, PlannerPage.home);
    expect(find.textContaining('Ghost preview'), findsNothing);
    // The ghost tile itself (draft icon) must be gone from the calendar,
    // not just the drawer hint text.
    expect(find.byIcon(Icons.edit_calendar), findsNothing);
  });

  testWidgets('saving a plain FAB draft stays on the calendar',
      (tester) async {
    final calendarCubit = CalendarCubit();
    final nodeCubit = NodeCubit();
    final settingsCubit = SettingsCubit();
    final draftCubit = CalendarDraftCubit();
    final navigationCubit = NavigationCubit();
    final feedCubit = buildFeedCubit(calendarCubit, nodeCubit);

    await pumpCalendar(
      tester,
      calendarCubit: calendarCubit,
      feedCubit: feedCubit,
      settingsCubit: settingsCubit,
      draftCubit: draftCubit,
      navigationCubit: navigationCubit,
      nodeCubit: nodeCubit,
    );

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Homework block');
    await tester.pump();
    await tapDrawerAdd(tester);
    await tester.pumpAndSettle();

    expect(calendarCubit.state, hasLength(1));
    // No task link: the user stays where they are.
    expect(navigationCubit.state, PlannerPage.home);
  });

  testWidgets('saving a seeded event does not delete its source task',
      (tester) async {
    final calendarCubit = CalendarCubit();
    final nodeCubit = NodeCubit();
    final settingsCubit = SettingsCubit();
    final feedCubit = buildFeedCubit(calendarCubit, nodeCubit);
    final start = DateTime(2026, 10, 11, 9);
    calendarCubit.addEvent(PlannerEvent(
      id: 'evt:1',
      subject: 'Study physics',
      start: start,
      end: start.add(const Duration(hours: 1)),
      taskId: 'node:hw1',
    ));
    nodeCubit.addNode(Node(
      id: 'node:hw1',
      title: 'Study physics',
      createdAt: DateTime.now(),
      calendarEventId: 'evt:1',
    ));

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
            body: EventEditorForm(existing: calendarCubit.byId('evt:1')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final saveButton = find.widgetWithText(FilledButton, 'Save');
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    // Even a no-op edit save must keep the assignment the event was
    // scheduled from — it stays linked as the event's task.
    expect(nodeCubit.byId('node:hw1'), isNotNull);
    expect(nodeCubit.byId('node:hw1')!.calendarEventId, 'evt:1');
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
}
