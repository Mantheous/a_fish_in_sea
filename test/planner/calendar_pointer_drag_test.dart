import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_visibility_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:a_fish_in_sea/planner/view/calendar_side_panel.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

class MockStorage extends Mock implements Storage {}

class MockGoogleService extends Mock implements GoogleCalendarService {}

typedef CalendarHarness = ({
  CalendarCubit calendar,
  NodeCubit nodes,
  SettingsCubit settings,
  CalendarDraftCubit draft,
  FeedCubit feeds,
});

/// Pointer drags on a plan tile must follow the input device: a mouse drag
/// moves the tile immediately (it used to scroll the time grid, so a quick
/// click-drag never dropped the event), a touch long press still moves it,
/// and a quick touch swipe scrolls instead of dropping it somewhere. While a
/// drag nears the time ruler the grid scrolls so the tile can reach hours
/// outside the viewport — and it must never leave the day.
void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  Future<CalendarHarness> pumpCalendar(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calendarCubit = CalendarCubit();
    final nodeCubit = NodeCubit();
    final settingsCubit = SettingsCubit();
    final draftCubit = CalendarDraftCubit();
    final feedCubit = FeedCubit(
      calendarCubit: calendarCubit,
      nodeCubit: nodeCubit,
      icalService: IcalService(),
      googleService: MockGoogleService(),
      proxyBase: () => '',
    );
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider(create: (_) => UndoCubit()),
          BlocProvider(create: (_) => NavigationCubit()),
          BlocProvider.value(value: settingsCubit),
          BlocProvider.value(value: calendarCubit),
          BlocProvider.value(value: draftCubit),
          BlocProvider(create: (_) => CalendarVisibilityCubit()),
          BlocProvider(create: (_) => ReportingCubit()),
          BlocProvider.value(value: nodeCubit),
          BlocProvider.value(value: feedCubit),
        ],
        child: const MaterialApp(home: CalendarPage()),
      ),
    );
    await tester.pumpAndSettle();
    return (
      calendar: calendarCubit,
      nodes: nodeCubit,
      settings: settingsCubit,
      draft: draftCubit,
      feeds: feedCubit,
    );
  }

  /// The vertical scroll position of the visible time grid. SfCalendar lays
  /// the neighbouring day pages beside the visible one, so pick the page
  /// centered in the calendar rather than the first or tallest.
  ScrollPosition gridScroll(WidgetTester tester) {
    final calendar = tester.getRect(find.byType(SfCalendar));
    final states = tester.stateList<ScrollableState>(
      find.descendant(
        of: find.byType(SfCalendar),
        matching: find.byType(Scrollable),
      ),
    );
    final visible = states
        .where(
          (state) =>
              state.position.axis == Axis.vertical &&
              calendar.contains(
                tester.getRect(find.byWidget(state.widget)).center,
              ),
        )
        .toList()
      ..sort(
        (a, b) => b.position.viewportDimension.compareTo(
          a.position.viewportDimension,
        ),
      );
    return visible.first.position;
  }

  Future<void> enableWeekPlanReport(WidgetTester tester) async {
    await tester.tap(find.text('Week'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plan + Report'));
    await tester.pumpAndSettle();
  }

  /// Opens the create flow with a task-seeded ghost at the current slot.
  void openGhost(CalendarHarness app) {
    final due = DateTime.now();
    app.draft.requestDraft(
      draftSeedFromNode(
        Node(
          id: 'node:hw1',
          title: 'Study physics',
          createdAt: DateTime.now(),
          schedule: ScheduleFacet(
            due: DateTime(due.year, due.month, due.day, 23, 59),
          ),
          sourceEventId: 'evt:x',
        ),
      ),
    );
  }

  PlannerEvent currentDraft(WidgetTester tester) => tester
      .widget<CalendarSidePanel>(find.byType(CalendarSidePanel))
      .draft!;

  Finder draftTile() =>
      find.byKey(const ValueKey('tile:$calendarDraftEventId')).first;

  /// Drags from [from] by [by] in small steps, like a real pointer, so the
  /// drag recognizer sees movement after it wins the arena.
  Future<void> dragBy(
    WidgetTester tester,
    Offset from,
    Offset by, {
    PointerDeviceKind kind = PointerDeviceKind.mouse,
    int steps = 8,
    VoidCallback? onBeforeUp,
  }) async {
    final gesture = await tester.startGesture(from, kind: kind);
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(by / steps.toDouble());
      await tester.pump(const Duration(milliseconds: 16));
    }
    onBeforeUp?.call();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('mouse drag moves the ghost instead of scrolling the grid',
      (tester) async {
    final app = await pumpCalendar(tester);
    await enableWeekPlanReport(tester);
    openGhost(app);
    await tester.pumpAndSettle();

    final before = currentDraft(tester);
    final scrollBefore = gridScroll(tester).pixels;

    double? scrollDuringDrag;
    await dragBy(
      tester,
      tester.getCenter(draftTile()),
      const Offset(0, 100),
      onBeforeUp: () => scrollDuringDrag = gridScroll(tester).pixels,
    );

    final after = currentDraft(tester);
    expect(
      after.start.isAfter(before.start),
      isTrue,
      reason: 'mouse drag should move the ghost later, got ${after.start}',
    );
    expect(
      after.end.difference(after.start),
      before.end.difference(before.start),
    );
    expect(
      scrollDuringDrag,
      scrollBefore,
      reason: 'the drag must not scroll the time grid',
    );
  });

  testWidgets('mouse drag moves a real plan event and not the grid',
      (tester) async {
    final app = await pumpCalendar(tester);
    await tester.tap(find.text('Week'));
    await tester.pumpAndSettle();
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, 10);
    app.calendar.addEvent(
      PlannerEvent(
        id: 'evt:drag',
        subject: 'Move me',
        start: start,
        end: start.add(const Duration(hours: 1)),
      ),
    );
    await tester.pumpAndSettle();
    // Pin the grid to the top of the day so the 10:00 tile is on screen
    // regardless of what time the test host clock is at.
    gridScroll(tester).jumpTo(0);
    await tester.pumpAndSettle();

    final scrollBefore = gridScroll(tester).pixels;
    double? scrollDuringDrag;
    await dragBy(
      tester,
      tester.getCenter(find.text('Move me', findRichText: true).first),
      const Offset(0, 80),
      onBeforeUp: () => scrollDuringDrag = gridScroll(tester).pixels,
    );

    final moved = app.calendar.byId('evt:drag')!;
    expect(
      moved.start.isAfter(start),
      isTrue,
      reason: 'mouse drag should move the event, got ${moved.start}',
    );
    expect(moved.end.difference(moved.start), const Duration(hours: 1));
    expect(scrollDuringDrag, scrollBefore);
  });

  testWidgets('touch long-press drag still moves the ghost', (tester) async {
    final app = await pumpCalendar(tester);
    await enableWeekPlanReport(tester);
    openGhost(app);
    await tester.pumpAndSettle();

    final before = currentDraft(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(draftTile()),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final after = currentDraft(tester);
    expect(
      after.start.isBefore(before.start),
      isTrue,
      reason: 'long-press drag should move the ghost, got ${after.start}',
    );
  });

  testWidgets('a quick touch swipe scrolls instead of dropping the tile',
      (tester) async {
    final app = await pumpCalendar(tester);
    await enableWeekPlanReport(tester);
    openGhost(app);
    await tester.pumpAndSettle();

    final before = currentDraft(tester);
    final scrollBefore = gridScroll(tester).pixels;
    final gesture = await tester.startGesture(
      tester.getCenter(draftTile()),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final scrolledDuringSwipe = gridScroll(tester).pixels;
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      scrolledDuringSwipe,
      lessThan(scrollBefore),
      reason: 'a swipe on a tile should still scroll the calendar',
    );
    expect(
      currentDraft(tester).start,
      before.start,
      reason: 'a quick swipe must not drop the tile somewhere',
    );
  });

  testWidgets('holding a drag over the time ruler auto-scrolls the grid',
      (tester) async {
    final app = await pumpCalendar(tester);
    await enableWeekPlanReport(tester);
    openGhost(app);
    await tester.pumpAndSettle();

    final before = currentDraft(tester);
    final scrollBefore = gridScroll(tester).pixels;
    final grid = tester.getRect(find.byType(SfCalendar));
    final gesture = await tester.startGesture(
      tester.getCenter(draftTile()),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 16));
    // Park the pointer high over the time ruler: the calendar should scroll
    // toward earlier hours even though the pointer stands still.
    await gesture.moveTo(Offset(grid.left + 20, grid.top + 60));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 300));
    // Read while the drag is still live: the drop re-selects the ghost, and
    // the calendar scrolls back to it.
    final scrolledDuringDrag = gridScroll(tester).pixels;
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      scrolledDuringDrag,
      lessThan(scrollBefore),
      reason: 'holding the drag over the ruler should scroll the grid',
    );
    // The ruler is the scroll handle, not a day column: the ghost must stay
    // on the day it was grabbed on.
    expect(
      currentDraft(tester).start.day,
      before.start.day,
      reason: 'dragging over the ruler must not move the ghost to another day',
    );
    // A fast drop can land outside the visible hours; the grid must reveal
    // it instead of leaving the ghost seemingly gone.
    expect(
      tester.getRect(find.byType(SfCalendar)).contains(
        tester.getRect(draftTile()).center,
      ),
      isTrue,
      reason: 'the dropped ghost should stay visible',
    );
  });

  testWidgets('holding a drag over the time ruler auto-scrolls in Plans too',
      (tester) async {
    final app = await pumpCalendar(tester);
    await tester.tap(find.text('Week'));
    await tester.pumpAndSettle();
    openGhost(app);
    await tester.pumpAndSettle();

    final scrollBefore = gridScroll(tester).pixels;
    final grid = tester.getRect(find.byType(SfCalendar));
    final gesture = await tester.startGesture(
      tester.getCenter(draftTile()),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveTo(Offset(grid.left + 20, grid.top + 60));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 300));
    final scrolledDuringDrag = gridScroll(tester).pixels;
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      scrolledDuringDrag,
      lessThan(scrollBefore),
      reason: 'the plan calendar should follow the drag over its ruler',
    );
  });

  testWidgets('dragging past midnight clamps instead of losing the ghost',
      (tester) async {
    final app = await pumpCalendar(tester);
    await enableWeekPlanReport(tester);
    openGhost(app);
    await tester.pumpAndSettle();

    final before = currentDraft(tester);
    await dragBy(
      tester,
      tester.getCenter(draftTile()),
      const Offset(0, 5000),
      steps: 20,
    );

    final after = currentDraft(tester);
    expect(after.start.day, before.start.day);
    expect(after.start.isAfter(before.start), isTrue);
    expect(draftTile(), findsOneWidget);
  });
}
