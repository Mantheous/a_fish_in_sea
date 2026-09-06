import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/task_cubit.dart';
import 'package:a_fish_in_sea/planner/model/task.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
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

  group('draftSeedFromTask', () {
    test('builds a 9am ghost on the due date', () {
      final due = DateTime(2026, 9, 10, 23, 59);
      final seed = draftSeedFromTask(
        Task(
          id: 'task:hw1',
          title: 'Problem set 5',
          notes: 'Chapter 3',
          due: due,
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
      final seed = draftSeedFromTask(
        const Task(id: 'task:t1', title: 'Read me'),
        now: now,
      );
      expect(seed.start, DateTime(2026, 9, 5, 9));
    });
  });

  group('CalendarDraftCubit', () {
    test('request/take/clear roundtrip', () {
      final cubit = CalendarDraftCubit();
      expect(cubit.state, isNull);
      final seed = draftSeedFromTask(
        const Task(id: 'task:t1', title: 'Hi'),
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
          BlocProvider(create: (_) => TaskCubit()),
          BlocProvider.value(value: feedCubit),
        ],
        child: const MaterialApp(home: CalendarPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  FeedCubit buildFeedCubit(
    CalendarCubit calendarCubit,
    TaskCubit taskCubit,
  ) =>
      FeedCubit(
        calendarCubit: calendarCubit,
        taskCubit: taskCubit,
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
    final taskCubit = TaskCubit();
    final settingsCubit = SettingsCubit();
    final draftCubit = CalendarDraftCubit();
    final feedCubit = buildFeedCubit(calendarCubit, taskCubit);
    draftCubit.requestDraft(
      draftSeedFromTask(
        Task(
          id: 'task:hw1',
          title: 'Study physics',
          due: DateTime.now(),
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
    final taskCubit = TaskCubit();
    final settingsCubit = SettingsCubit();
    final draftCubit = CalendarDraftCubit();
    final feedCubit = buildFeedCubit(calendarCubit, taskCubit);

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
    final taskCubit = TaskCubit();
    final settingsCubit = SettingsCubit();
    final navigationCubit = NavigationCubit();
    final draftCubit = CalendarDraftCubit();
    final feedCubit = buildFeedCubit(calendarCubit, taskCubit);
    taskCubit.addTask(
      Task(
        id: 'task:hw1',
        title: 'Problem set 5',
        due: DateTime(2026, 9, 10, 23, 59),
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
          BlocProvider.value(value: taskCubit),
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
