import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/tasks_tab_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/tasks_view_options_cubit.dart';
import 'package:a_fish_in_sea/planner/model/task_filter.dart';
import 'package:a_fish_in_sea/planner/model/task_rule.dart';
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

  group('TasksViewOptionsCubit', () {
    test('legacy defaults live on as editable presets', () {
      final cubit = TasksViewOptionsCubit();
      addTearDown(cubit.close);
      expect(cubit.state.filters.map((f) => f.id), ['all', 'today', 'overdue']);
      expect(cubit.state.activeFilterId, 'all');
      expect(cubit.state.hasCustomFilters, isFalse);
    });
  });

  group('Tasks page view options', () {
    late TasksViewOptionsCubit viewOptions;

    Future<void> pumpTasks(WidgetTester tester) async {
      final now = DateTime.now();
      final todayNoon =
          DateTime(now.year, now.month, now.day, 12);
      final nodeCubit = NodeCubit();
      final calendarCubit = CalendarCubit();
      viewOptions = TasksViewOptionsCubit();
      addTearDown(() async {
        await nodeCubit.close();
        await calendarCubit.close();
        await viewOptions.close();
      });
      Node personal(String id, String title, DateTime? due,
          {NodeStatus status = NodeStatus.open}) {
        return Node(
          id: id,
          title: title,
          createdAt: now,
          status: status,
          schedule: due == null ? null : ScheduleFacet(due: due),
        );
      }

      nodeCubit.addNode(personal(
          'node:today', 'Due today task', todayNoon));
      nodeCubit.addNode(personal('node:overdue', 'Overdue task',
          todayNoon.subtract(const Duration(days: 2))));
      // Due later this calendar week (but not today): next Sunday at the
      // latest, clamped to tomorrow when tomorrow is past Sunday.
      var inWeek = todayNoon.add(const Duration(days: 3));
      var daysToSunday = DateTime.sunday - now.weekday;
      if (daysToSunday <= 0) daysToSunday += 7;
      final endExclusive = DateTime(now.year, now.month, now.day)
          .add(Duration(days: daysToSunday + 1));
      if (!inWeek.isBefore(endExclusive)) {
        inWeek = todayNoon.add(const Duration(days: 1));
      }
      if (inWeek.day != todayNoon.day) {
        nodeCubit.addNode(
            personal('node:week', 'Due this week task', inWeek));
      }
      nodeCubit.addNode(personal('node:later', 'Far future task',
          todayNoon.add(const Duration(days: 60))));
      nodeCubit.addNode(personal('node:done', 'Done today task',
          todayNoon,
          status: NodeStatus.done));
      nodeCubit.addNode(Node(
        id: 'node:hw-today',
        title: 'Due today homework',
        createdAt: now,
        schedule: ScheduleFacet(due: todayNoon),
        sourceEventId: 'evt:hw-today',
        classLabel: 'Physics',
      ));
      nodeCubit.addNode(Node(
        id: 'node:hw-later',
        title: 'Far future homework',
        createdAt: now,
        schedule:
            ScheduleFacet(due: todayNoon.add(const Duration(days: 60))),
        sourceEventId: 'evt:hw-later',
        classLabel: 'Physics',
      ));
      final feedCubit = FeedCubit(
        calendarCubit: calendarCubit,
        nodeCubit: nodeCubit,
        icalService: IcalService(),
        googleService: MockGoogleService(),
        proxyBase: () => '',
      );
      addTearDown(feedCubit.close);
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider(create: (_) => UndoCubit()),
            BlocProvider(create: (_) => NavigationCubit()),
            BlocProvider(create: (_) => SettingsCubit()),
            BlocProvider(create: (_) => TasksTabCubit()),
            BlocProvider.value(value: calendarCubit),
            BlocProvider(create: (_) => CalendarDraftCubit()),
            BlocProvider.value(value: nodeCubit),
            BlocProvider.value(value: feedCubit),
            BlocProvider.value(value: viewOptions),
          ],
          child: const MaterialApp(home: TasksPage()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('off by default; highlight tints only week rows', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        await pumpTasks(tester);
        expect(find.bySemanticsLabel('Due this week'), findsNothing);
        expect(find.bySemanticsLabel('Due today'), findsNothing);

        await tester.tap(find.byTooltip('View options'));
        await tester.pumpAndSettle();
        expect(find.text('Views'), findsOneWidget);
        expect(find.text('Rules'), findsOneWidget);
        // The stock week rule is the only switch in the sheet: turning
        // it on is the old highlight toggle. The sheet is taller than
        // the test viewport, so look past the fold, then scroll to it.
        await tester.ensureVisible(
          find.byType(Switch, skipOffstage: false),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        expect(viewOptions.state.hasHighlightRule, isTrue);
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();

        // Rows due today get the hotter orange cue under its own label …
        // (both the personal task and the homework row show on To-Do).
        final today = find.bySemanticsLabel('Due today');
        expect(today, findsNWidgets(2));
        expect(
          find.descendant(
            of: today,
            matching: find.text('Due today task'),
          ),
          findsOneWidget,
        );
        // … while the rest of the week keeps the week tint.
        final highlighted = find.bySemanticsLabel('Due this week');
        expect(highlighted, findsWidgets);
        expect(
          find.descendant(
            of: highlighted,
            matching: find.text('Due today task'),
          ),
          findsNothing,
        );
        // Overdue and far-future rows never highlight.
        expect(
          find.descendant(
            of: highlighted,
            matching: find.text('Overdue task'),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: highlighted,
            matching: find.text('Far future task'),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: highlighted,
            matching: find.text('Done today task'),
          ),
          findsNothing,
        );

        // The Homework tab gets the same treatment.
        await tester.tap(find.text('Homework'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.bySemanticsLabel('Due today'),
            matching: find.text('Due today homework'),
          ),
          findsOneWidget,
        );
      } finally {
        handle.dispose();
      }
    });

    testWidgets('due-today rows glow orange, week rows keep the week tint',
        (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await pumpTasks(tester);
        viewOptions.setRuleEnabled('rule:week', true);
        await tester.pumpAndSettle();

        Finder tinted(Color color) => find.ancestor(
              of: find.text('Due today task'),
              matching: find.byWidgetPredicate(
                (w) =>
                    w is Container &&
                    w.decoration is BoxDecoration &&
                    (w.decoration! as BoxDecoration).color == color,
              ),
            );
        // Today rows sit in the orange container …
        expect(tinted(Colors.orange.withAlpha(41)), findsOneWidget);
        // … while a later-this-week row keeps the tertiary container.
        final scheme =
            Theme.of(tester.element(find.text('Due today task'))).colorScheme;
        final weekRow = find.ancestor(
          of: find.text('Due this week task'),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration! as BoxDecoration).color ==
                    scheme.tertiaryContainer,
          ),
        );
        expect(weekRow, findsOneWidget);
      } finally {
        handle.dispose();
      }
    });

    testWidgets('today filter shows only items due today', (tester) async {
      await pumpTasks(tester);
      await tester.tap(find.byTooltip('View options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Today'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(viewOptions.state.activeFilterId, 'today');
      expect(find.text('Due today task'), findsOneWidget);
      expect(find.text('Overdue task'), findsNothing);
      expect(find.text('Far future task'), findsNothing);
      // Completed items are hidden while a filter is on.
      expect(find.text('Done today task'), findsNothing);

      await tester.tap(find.text('Homework'));
      await tester.pumpAndSettle();
      expect(find.text('Due today homework'), findsOneWidget);
      expect(find.text('Far future homework'), findsNothing);
    });

    testWidgets('overdue filter shows only overdue items', (tester) async {
      await pumpTasks(tester);
      await tester.tap(find.byTooltip('View options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Overdue'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(viewOptions.state.activeFilterId, 'overdue');
      expect(find.text('Overdue task'), findsOneWidget);
      expect(find.text('Due today task'), findsNothing);
      expect(find.text('Far future task'), findsNothing);
    });

    testWidgets('clear resets rules and filter', (tester) async {
      await pumpTasks(tester);
      viewOptions.setRuleEnabled('rule:week', true);
      viewOptions.setActiveFilter('today');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('View options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(viewOptions.state, const TasksViewOptionsState());
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Far future task'), findsOneWidget);
    });

    testWidgets('hide rule removes matching rows instead of tinting',
        (tester) async {
      await pumpTasks(tester);
      viewOptions.addRule(const TaskRule(
        id: 'hide-week',
        selector: TaskFilter(
            id: 'hide-week', name: 'Hide week', date: TaskFilterDate.thisWeek),
        effect: TaskRuleEffect.hide,
      ));
      await tester.pumpAndSettle();

      expect(viewOptions.state.isFiltering, isTrue);
      expect(find.text('Due today task'), findsNothing);
      expect(find.text('Due this week task'), findsNothing);
      // Outside the week window: overdue and far-future stay.
      expect(find.text('Overdue task'), findsOneWidget);
      expect(find.text('Far future task'), findsOneWidget);
    });

    testWidgets('custom rule color tints week rows', (tester) async {
      await pumpTasks(tester);
      viewOptions.setRuleEnabled('rule:week', true);
      viewOptions.setRuleColor('rule:week', 0xFF42A5F5);
      await tester.pumpAndSettle();

      final tinted = find.ancestor(
        of: find.text('Due this week task'),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).color ==
                  const Color(0xFF42A5F5).withAlpha(41),
        ),
      );
      expect(tinted, findsOneWidget);
    });

    testWidgets('new filter from the builder activates on save',
        (tester) async {
      await pumpTasks(tester);
      await tester.tap(find.byTooltip('View options'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('New filter'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New filter'));
      await tester.pumpAndSettle();
      expect(find.text('Edit filter'), findsNothing);
      await tester.dragUntilVisible(
        find.text('Add filter'),
        find.byType(ListView).last,
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add filter'));
      await tester.pumpAndSettle();

      expect(viewOptions.state.filters, hasLength(4));
      expect(viewOptions.state.activeFilterId, startsWith('custom:'));
      expect(viewOptions.state.isFiltering, isTrue);
    });

    testWidgets('custom range filter keeps overdue through tomorrow',
        (tester) async {
      await pumpTasks(tester);
      await tester.tap(find.byTooltip('View options'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.text('New filter', skipOffstage: false),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('New filter'));
      await tester.pumpAndSettle();

      // Switch the date window to the rolling custom range.
      await tester.tap(find.byType(DropdownButtonFormField<TaskFilterDate>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom range').last);
      await tester.pumpAndSettle();
      // The one-tap preset for overdue + today + tomorrow.
      await tester.ensureVisible(
        find.text('Tomorrow or earlier', skipOffstage: false),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tomorrow or earlier'));
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.text('Add filter'),
        find.byType(ListView).last,
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add filter'));
      await tester.pumpAndSettle();

      expect(viewOptions.state.activeFilter.date, TaskFilterDate.custom);
      expect(find.text('Overdue task'), findsOneWidget);
      expect(find.text('Due today task'), findsOneWidget);
      expect(find.text('Far future task'), findsNothing);
      // Completed items stay hidden while the filter is on.
      expect(find.text('Done today task'), findsNothing);
    });

    testWidgets('edit rules opens the dedicated rules page', (tester) async {
      await pumpTasks(tester);
      await tester.tap(find.byTooltip('View options'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.text('Edit rules', skipOffstage: false),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit rules'));
      await tester.pumpAndSettle();

      expect(find.text('Task rules'), findsOneWidget);
      expect(find.text('Due this week'), findsOneWidget);
      // Priority copy explains conflict resolution.
      expect(find.textContaining('topmost matching highlight'), findsOneWidget);
      // Toggling the stock rule on the page tints the list behind it.
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(viewOptions.state.hasHighlightRule, isTrue);
    });

    testWidgets('works without a TasksViewOptionsCubit provider',
        (tester) async {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      final settings = SettingsCubit();
      final navigation = NavigationCubit();
      final drafts = CalendarDraftCubit();
      final tabs = TasksTabCubit();
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
        await tabs.close();
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
            BlocProvider.value(value: tabs),
          ],
          child: const MaterialApp(home: TasksPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('To-Do'), findsOneWidget);
    });
  });
}
