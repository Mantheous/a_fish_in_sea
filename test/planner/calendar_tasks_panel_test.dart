import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/node_tile.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_panel_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_visibility_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/tasks_tab_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/tasks_view_options_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:a_fish_in_sea/planner/view/calendar_side_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

class MockStorage extends Mock implements Storage {}

class MockGoogleService extends Mock implements GoogleCalendarService {}

/// The calendar's right-hand panel: the task list rests there on wide
/// screens, a task tap selects its calendar event, and the node menu stays
/// in the tile's ⋮.
void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  Node openNode(
    String id,
    String title, {
    String? calendarEventId,
    DateTime? createdAt,
  }) =>
      Node(
        id: id,
        title: title,
        createdAt: createdAt ?? DateTime.now(),
        calendarEventId: calendarEventId,
      );

  Future<
      ({
        NodeCubit nodes,
        CalendarCubit calendar,
        CalendarDraftCubit drafts,
        NavigationCubit navigation,
      })> pumpCalendar(
    WidgetTester tester, {
    Size size = const Size(1280, 800),
    List<Node> nodes = const [],
    List<PlannerEvent> events = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final nodeCubit = NodeCubit();
    final calendarCubit = CalendarCubit();
    final settingsCubit = SettingsCubit();
    final draftCubit = CalendarDraftCubit();
    final navigationCubit = NavigationCubit();
    final tasksTabCubit = TasksTabCubit();
    final panelCubit = CalendarPanelCubit();
    final viewOptionsCubit = TasksViewOptionsCubit();
    final feedCubit = FeedCubit(
      calendarCubit: calendarCubit,
      nodeCubit: nodeCubit,
      icalService: IcalService(),
      googleService: MockGoogleService(),
      proxyBase: () => '',
    );
    for (final node in nodes) {
      nodeCubit.addNode(node);
    }
    for (final event in events) {
      calendarCubit.addEvent(event);
    }
    addTearDown(() async {
      await nodeCubit.close();
      await calendarCubit.close();
      await settingsCubit.close();
      await draftCubit.close();
      await navigationCubit.close();
      await tasksTabCubit.close();
      await panelCubit.close();
      await viewOptionsCubit.close();
      await feedCubit.close();
    });
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider(create: (_) => UndoCubit()),
          BlocProvider.value(value: navigationCubit),
          BlocProvider.value(value: settingsCubit),
          BlocProvider.value(value: calendarCubit),
          BlocProvider.value(value: draftCubit),
          BlocProvider.value(value: tasksTabCubit),
          BlocProvider.value(value: panelCubit),
          BlocProvider.value(value: viewOptionsCubit),
          BlocProvider(create: (_) => CalendarVisibilityCubit()),
          BlocProvider.value(value: nodeCubit),
          BlocProvider.value(value: feedCubit),
        ],
        child: const MaterialApp(home: CalendarPage()),
      ),
    );
    await tester.pumpAndSettle();
    return (
      nodes: nodeCubit,
      calendar: calendarCubit,
      drafts: draftCubit,
      navigation: navigationCubit,
    );
  }

  Finder panelTile(String title) => find.descendant(
        of: find.byType(NodeTile),
        matching: find.text(title),
      );

  testWidgets('wide screens rest on the task list inside the side panel',
      (tester) async {
    await pumpCalendar(
      tester,
      nodes: [openNode('n1', 'Water the plants')],
    );
    await tester.pump();

    expect(find.text('Tasks'), findsOneWidget);
    expect(panelTile('Water the plants'), findsOneWidget);
    // Nothing selected: no event detail replaces the list.
    expect(find.text('Event details'), findsNothing);
  });

  testWidgets('the toolbar toggle closes and reopens the panel any time',
      (tester) async {
    await pumpCalendar(
      tester,
      nodes: [openNode('n1', 'Water the plants')],
    );
    await tester.pump();
    expect(panelTile('Water the plants'), findsOneWidget);

    await tester.tap(find.byTooltip('Hide side panel'));
    await tester.pumpAndSettle();

    expect(find.text('Tasks'), findsNothing);
    expect(find.byType(NodeTile), findsNothing);

    await tester.tap(find.byTooltip('Show tasks panel'));
    await tester.pumpAndSettle();

    expect(find.text('Tasks'), findsOneWidget);
    expect(panelTile('Water the plants'), findsOneWidget);
  });

  testWidgets('narrow screens keep the panel off and hide the toggle',
      (tester) async {
    await pumpCalendar(
      tester,
      size: const Size(500, 900),
      nodes: [openNode('n1', 'Water the plants')],
    );
    await tester.pump();

    expect(find.byTooltip('Show tasks panel'), findsNothing);
    expect(find.byType(NodeTile), findsNothing);
  });

  testWidgets(
      'tapping a task selects its calendar event instead of opening the node editor',
      (tester) async {
    final now = DateTime.now();
    final eventDay = now.add(const Duration(days: 3));
    final start = DateTime(eventDay.year, eventDay.month, eventDay.day, 14);
    await pumpCalendar(
      tester,
      nodes: [openNode('n1', 'Problem set 5', calendarEventId: 'e1')],
      events: [
        PlannerEvent(
          id: 'e1',
          subject: 'PS5 work block',
          start: start,
          end: start.add(const Duration(hours: 1)),
          isTask: true,
          taskId: 'n1',
        ),
      ],
    );
    await tester.pump();
    // Unselected events show no resize handles.
    expect(find.bySemanticsLabel('Drag to change start time'), findsNothing);

    await tester.tap(panelTile('Problem set 5'));
    await tester.pumpAndSettle();

    // Panel stays on the task list; no node editor dialog.
    expect(panelTile('Problem set 5'), findsOneWidget);
    expect(find.text('Event details'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    // The calendar moved to the event's day and selected its tile.
    expect(find.text('PS5 work block'), findsWidgets);
    expect(find.bySemanticsLabel('Drag to change start time'), findsOneWidget);
    final sfCalendar = tester.widget<SfCalendar>(find.byType(SfCalendar));
    final display = sfCalendar.controller!.displayDate!;
    expect(
      DateTime(display.year, display.month, display.day),
      DateTime(start.year, start.month, start.day),
    );
  });

  testWidgets('the tile menu still opens the node editor', (tester) async {
    await pumpCalendar(
      tester,
      nodes: [openNode('n1', 'Problem set 5', calendarEventId: 'e1')],
    );
    await tester.pump();

    await tester.tap(
      find.descendant(
        of: find.byType(NodeTile),
        matching: find.byIcon(Icons.more_vert),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    // The editor opened on the tapped task.
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Problem set 5'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('tapping an unscheduled task drops a ghost on its due date',
      (tester) async {
    final now = DateTime.now();
    final due = DateTime(now.year, now.month, now.day)
        .add(const Duration(days: 2));
    await pumpCalendar(
      tester,
      nodes: [
        Node(
          id: 'n1',
          title: 'Problem set 5',
          createdAt: now,
          schedule: ScheduleFacet(
            due: DateTime(due.year, due.month, due.day, 23, 59),
          ),
        ),
      ],
    );
    await tester.pump();

    await tester.tap(panelTile('Problem set 5'));
    await tester.pumpAndSettle();

    // Straight into the create flow with a ghost — no schedule sheet, no
    // snackbar detour.
    expect(find.text('New event'), findsOneWidget);
    expect(find.textContaining('Ghost preview'), findsOneWidget);
    expect(find.byIcon(Icons.edit_calendar), findsWidgets);
    // The ghost (and the calendar) land on the due day.
    final sfCalendar = tester.widget<SfCalendar>(find.byType(SfCalendar));
    final display = sfCalendar.controller!.displayDate!;
    expect(
      DateTime(display.year, display.month, display.day),
      DateTime(due.year, due.month, due.day),
    );
  });

  testWidgets('the back arrow leaves an event detail for the task list',
      (tester) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, 10);
    await pumpCalendar(
      tester,
      nodes: [openNode('n1', 'Problem set 5', calendarEventId: 'e1')],
      events: [
        PlannerEvent(
          id: 'e1',
          subject: 'PS5 work block',
          start: start,
          end: start.add(const Duration(hours: 1)),
          isTask: true,
          taskId: 'n1',
        ),
      ],
    );
    await tester.pump();

    await tester.tap(find.text('PS5 work block', findRichText: true).first);
    await tester.pumpAndSettle();
    expect(find.text('Event details'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to tasks'));
    await tester.pumpAndSettle();

    expect(find.text('Event details'), findsNothing);
    expect(panelTile('Problem set 5'), findsOneWidget);
  });

  testWidgets('deleting the open event keeps the panel on the task list',
      (tester) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, 10);
    final seeded = await pumpCalendar(
      tester,
      events: [
        PlannerEvent(
          id: 'e1',
          subject: 'Lunch',
          start: start,
          end: start.add(const Duration(hours: 1)),
        ),
      ],
    );
    await tester.pump();

    await tester.tap(find.text('Lunch', findRichText: true).first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit event'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // The event is gone but the panel stays open on the task list.
    expect(seeded.calendar.byId('e1'), isNull);
    expect(find.text('Event deleted'), findsOneWidget);
    expect(find.byType(CalendarSidePanel), findsOneWidget);
    expect(find.text('Tasks'), findsOneWidget);
    expect(find.text('Edit event'), findsNothing);
    expect(find.text('Event details'), findsNothing);
  });

  testWidgets('a draft seeded while the panel is open stays on the calendar',
      (tester) async {
    final seeded = await pumpCalendar(
      tester,
      nodes: [openNode('n1', 'Problem set 5')],
    );
    await tester.pump();

    // Schedule → Pick time on calendar from the panel: the seed lands while
    // the calendar page is already open (listener path, not page mount).
    seeded.drafts.requestDraft(
      draftSeedFromNode(seeded.nodes.byId('n1')!),
    );
    await tester.pumpAndSettle();
    expect(find.text('New event'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(seeded.calendar.state, hasLength(1));
    // The task list is the next scheduling surface — no page switch.
    expect(seeded.navigation.state, PlannerPage.home);
    expect(find.text('Event details'), findsNothing);
    expect(panelTile('Problem set 5'), findsOneWidget);
  });

  testWidgets('dragging the panel edge resizes it, with sane bounds',
      (tester) async {
    await pumpCalendar(tester, nodes: [openNode('n1', 'Water the plants')]);
    await tester.pump();
    final panel = find.byType(CalendarSidePanel);
    expect(tester.getSize(panel).width, calendarPanelDefaultWidth);

    // Drag the left edge left → wider, clamped at the hard maximum.
    await tester.drag(
      find.byKey(calendarPanelResizeHandleKey),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).width, calendarPanelMaxWidth);

    // Drag right → narrower, clamped at the minimum.
    await tester.drag(
      find.byKey(calendarPanelResizeHandleKey),
      const Offset(550, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).width, calendarPanelMinWidth);
  });

  testWidgets('double-clicking the panel edge resets the width',
      (tester) async {
    await pumpCalendar(tester, nodes: [openNode('n1', 'Water the plants')]);
    await tester.pump();
    final panel = find.byType(CalendarSidePanel);

    await tester.drag(
      find.byKey(calendarPanelResizeHandleKey),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).width, calendarPanelMaxWidth);

    await tester.tap(find.byKey(calendarPanelResizeHandleKey));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(calendarPanelResizeHandleKey));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).width, calendarPanelDefaultWidth);
  });

  testWidgets('a dragged width survives closing and reopening the panel',
      (tester) async {
    await pumpCalendar(tester, nodes: [openNode('n1', 'Water the plants')]);
    await tester.pump();

    await tester.drag(
      find.byKey(calendarPanelResizeHandleKey),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Hide side panel'));
    await tester.pumpAndSettle();
    expect(find.byType(CalendarSidePanel), findsNothing);

    await tester.tap(find.byTooltip('Show tasks panel'));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(CalendarSidePanel)).width,
      calendarPanelMaxWidth,
    );
  });

  testWidgets('the panel never squeezes the calendar below 360px',
      (tester) async {
    // 900px window: the panel starts closed; its maximum is 900-360, so the
    // calendar always keeps room beside it.
    await pumpCalendar(
      tester,
      size: const Size(900, 800),
      nodes: [openNode('n1', 'Water the plants')],
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Show tasks panel'));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(calendarPanelResizeHandleKey),
      const Offset(-450, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(CalendarSidePanel)).width, 540);
  });
}
