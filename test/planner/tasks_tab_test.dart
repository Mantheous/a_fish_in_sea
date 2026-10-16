import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/tasks_tab_cubit.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
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

  group('TasksTabCubit', () {
    test('defaults to To-Do and clamps to 0..1', () {
      final cubit = TasksTabCubit();
      expect(cubit.state, 0);
      cubit.setTab(1);
      expect(cubit.state, 1);
      cubit.setTab(5);
      expect(cubit.state, 1);
      cubit.setTab(-3);
      expect(cubit.state, 0);
    });
  });

  Future<void> pumpTasks(
    WidgetTester tester, {
    required TasksTabCubit tasksTab,
    required NodeCubit nodes,
    required CalendarCubit calendar,
    required FeedCubit feeds,
    required SettingsCubit settings,
    required NavigationCubit navigation,
    required CalendarDraftCubit drafts,
  }) async {
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider(create: (_) => UndoCubit()),
          BlocProvider.value(value: navigation),
          BlocProvider.value(value: settings),
          BlocProvider.value(value: calendar),
          BlocProvider.value(value: drafts),
          BlocProvider.value(value: nodes),
          BlocProvider.value(value: feeds),
          BlocProvider.value(value: tasksTab),
        ],
        child: const MaterialApp(home: TasksPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('tapping Homework remembers the tab across a rebuild',
      (tester) async {
    final tasksTab = TasksTabCubit();
    final nodes = NodeCubit();
    final calendar = CalendarCubit();
    final settings = SettingsCubit();
    final navigation = NavigationCubit();
    final drafts = CalendarDraftCubit();
    final feeds = FeedCubit(
      calendarCubit: calendar,
      nodeCubit: nodes,
      icalService: IcalService(),
      googleService: MockGoogleService(),
      proxyBase: () => '',
    );
    addTearDown(() async {
      await tasksTab.close();
      await nodes.close();
      await calendar.close();
      await settings.close();
      await navigation.close();
      await drafts.close();
      await feeds.close();
    });

    await pumpTasks(
      tester,
      tasksTab: tasksTab,
      nodes: nodes,
      calendar: calendar,
      feeds: feeds,
      settings: settings,
      navigation: navigation,
      drafts: drafts,
    );

    // Starts on To-Do.
    expect(tasksTab.state, 0);

    // Switch to Homework — the cubit must record it.
    await tester.tap(find.text('Homework'));
    await tester.pumpAndSettle();
    expect(tasksTab.state, 1);

    // Simulate the calendar round-trip: TasksPage is disposed while the
    // user picks a time, then rebuilt when _finishCreating navigates back.
    await tester.pumpWidget(Container());
    await tester.pump();
    await pumpTasks(
      tester,
      tasksTab: tasksTab,
      nodes: nodes,
      calendar: calendar,
      feeds: feeds,
      settings: settings,
      navigation: navigation,
      drafts: drafts,
    );

    // Rebuilt page must still be on the Homework tab (index 1), not reset
    // to To-Do. No homework nodes exist here, so the tab shows its empty
    // state — the tab index itself is the assertion.
    expect(find.text('No homework yet'), findsOneWidget);
    final tabElement = tester.element(find.byType(TabBar));
    expect(DefaultTabController.of(tabElement).index, 1);
  });

  testWidgets('homework add-to-calendar round-trip lands back on Homework',
      (tester) async {
    final tasksTab = TasksTabCubit();
    final nodes = NodeCubit();
    final calendar = CalendarCubit();
    final settings = SettingsCubit();
    final navigation = NavigationCubit();
    final drafts = CalendarDraftCubit();
    final feeds = FeedCubit(
      calendarCubit: calendar,
      nodeCubit: nodes,
      icalService: IcalService(),
      googleService: MockGoogleService(),
      proxyBase: () => '',
    );
    addTearDown(() async {
      await tasksTab.close();
      await nodes.close();
      await calendar.close();
      await settings.close();
      await navigation.close();
      await drafts.close();
      await feeds.close();
    });
    nodes.addNode(
      Node(
        id: 'node:hw1',
        title: 'Problem set 5',
        createdAt: DateTime(2026),
        schedule: ScheduleFacet(due: DateTime(2026, 9, 10, 23, 59)),
        sourceEventId: 'evt:x',
        classLabel: 'Physics',
      ),
    );

    await pumpTasks(
      tester,
      tasksTab: tasksTab,
      nodes: nodes,
      calendar: calendar,
      feeds: feeds,
      settings: settings,
      navigation: navigation,
      drafts: drafts,
    );
    await tester.tap(find.text('Homework'));
    await tester.pumpAndSettle();
    expect(tasksTab.state, 1);

    // Planning off the homework task navigates to the calendar …
    await tester.tap(find.byTooltip('Add to calendar').first);
    await tester.pump();
    expect(drafts.state, isNotNull);
    expect(navigation.state, PlannerPage.calendar);

    // … and when the calendar finishes creating it returns to Tasks,
    // where the rebuilt page must still show Homework.
    navigation.setPage(PlannerPage.tasks);
    await tester.pumpWidget(Container());
    await tester.pump();
    await pumpTasks(
      tester,
      tasksTab: tasksTab,
      nodes: nodes,
      calendar: calendar,
      feeds: feeds,
      settings: settings,
      navigation: navigation,
      drafts: drafts,
    );
    expect(find.text('Assignments by class'), findsOneWidget);
  });

  testWidgets('works without a TasksTabCubit provider (standalone tests)',
      (tester) async {
    final nodes = NodeCubit();
    final calendar = CalendarCubit();
    final settings = SettingsCubit();
    final navigation = NavigationCubit();
    final drafts = CalendarDraftCubit();
    final feeds = FeedCubit(
      calendarCubit: calendar,
      nodeCubit: nodes,
      icalService: IcalService(),
      googleService: MockGoogleService(),
      proxyBase: () => '',
    );
    addTearDown(() async {
      await nodes.close();
      await calendar.close();
      await settings.close();
      await navigation.close();
      await drafts.close();
      await feeds.close();
    });

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider(create: (_) => UndoCubit()),
          BlocProvider.value(value: navigation),
          BlocProvider.value(value: settings),
          BlocProvider.value(value: calendar),
          BlocProvider.value(value: drafts),
          BlocProvider.value(value: nodes),
          BlocProvider.value(value: feeds),
        ],
        child: const MaterialApp(home: TasksPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('To-Do'), findsOneWidget);
    expect(find.text('Homework'), findsOneWidget);
  });
}
