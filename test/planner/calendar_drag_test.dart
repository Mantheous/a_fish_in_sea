import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_visibility_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/model/event_reschedule.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:a_fish_in_sea/planner/view/calendar_grid_tracker.dart';
import 'package:a_fish_in_sea/planner/view/plan_tile_drag_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

class MockGoogleService extends Mock implements GoogleCalendarService {}

void main() {
  // Run with TZ=America/Denver to exercise both 2026 clock changes.
  for (final day in [DateTime(2026, 3, 8), DateTime(2026, 11, 1)]) {
    for (final crossDay in [false, true]) {
      for (final minutes in [0, 38, -38]) {
        test('drag on $day: crossDay=$crossDay, minutes=$minutes', () {
          final sourceDay = DateTime(
            day.year, day.month, day.day - (crossDay ? 1 : 0),
          );
          final start = DateTime(2026, sourceDay.month, sourceDay.day, 9);
          final original = PlannerEvent(
            id: 'dst-drag',
            subject: 'Clock change',
            start: start,
            end: start.add(const Duration(hours: 1)),
          );
          final tracker = PlanGridTracker(
            isMounted: () => true,
            timeGridViewportThreshold: 100,
          );
          addTearDown(tracker.dispose);
          final session = PlanTileDragSession(
            original: original,
            days: crossDay ? [sourceDay, day] : [day],
            stackRect: const Rect.fromLTWH(0, 0, 250, 800),
            cellWidth: 100,
            pixelsPerMinute: 2,
            isRtl: false,
            timeRulerWidth: 50,
            startMinutes: 0,
            endMinutes: 1440,
            tracker: tracker,
          );
          addTearDown(session.cancel);
          session.start(const Offset(100, 400));
          session.update(Offset(crossDay ? 200 : 120, 400 + minutes * 2.0));

          final expected = DateTime(
            day.year, day.month, day.day, 9, minutes,
          );
          expect(session.dropTime, expected);
          final preview = session.previewAt(15);
          final calendar = CalendarCubit()..addEvent(original);
          addTearDown(calendar.close);
          calendar.updateEvent(
            shiftEvent(original, session.finish(), snapMinutes: 15),
          );
          final saved = calendar.byId(original.id)!;
          expect(preview.start, snapToInterval(expected, 15));
          expect(saved.start, preview.start);
          expect(saved.end, preview.end);
          expect(saved.end.difference(saved.start), const Duration(hours: 1));
        });
      }
    }
  }

  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  Future<void> pumpCalendar(
    WidgetTester tester, {
    required CalendarCubit calendarCubit,
    required FeedCubit feedCubit,
    required SettingsCubit settingsCubit,
  }) async {
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider(create: (_) => UndoCubit()),
          BlocProvider(create: (_) => NavigationCubit()),
          BlocProvider.value(value: settingsCubit),
          BlocProvider.value(value: calendarCubit),
          BlocProvider(create: (_) => CalendarDraftCubit()),
          BlocProvider(create: (_) => CalendarVisibilityCubit()),
          BlocProvider(create: (_) => NodeCubit()),
          BlocProvider.value(value: feedCubit),
        ],
        child: const MaterialApp(home: CalendarPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('tapping an event opens the drawer', (tester) async {
    final calendarCubit = CalendarCubit();
    final nodeCubit = NodeCubit();
    final settingsCubit = SettingsCubit();
    final feedCubit = FeedCubit(
      calendarCubit: calendarCubit,
      nodeCubit: nodeCubit,
      icalService: IcalService(),
      googleService: MockGoogleService(),
      proxyBase: () => '',
    );
    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day, 10);
    calendarCubit.addEvent(PlannerEvent(
      id: 'evt:tap1',
      subject: 'Tap Me',
      start: dayStart,
      end: dayStart.add(const Duration(hours: 1)),
    ));

    await pumpCalendar(
      tester,
      calendarCubit: calendarCubit,
      feedCubit: feedCubit,
      settingsCubit: settingsCubit,
    );

    final all = find.text('Tap Me', findRichText: true);
    expect(all, findsWidgets);

    await tester.tap(find.text('Tap Me', findRichText: true).first);
    await tester.pumpAndSettle();
    expect(find.text('Event details'), findsOneWidget);
  });

  testWidgets('long-press hold suppresses the tap drawer', (tester) async {
    final calendarCubit = CalendarCubit();
    final nodeCubit = NodeCubit();
    final settingsCubit = SettingsCubit();
    final feedCubit = FeedCubit(
      calendarCubit: calendarCubit,
      nodeCubit: nodeCubit,
      icalService: IcalService(),
      googleService: MockGoogleService(),
      proxyBase: () => '',
    );
    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day, 10);
    calendarCubit.addEvent(PlannerEvent(
      id: 'evt:hold1',
      subject: 'Hold Me',
      start: dayStart,
      end: dayStart.add(const Duration(hours: 1)),
    ));

    await pumpCalendar(
      tester,
      calendarCubit: calendarCubit,
      feedCubit: feedCubit,
      settingsCubit: settingsCubit,
    );

    final center =
        tester.getCenter(find.text('Hold Me', findRichText: true).first);
    final gesture = await tester.startGesture(center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Event details'), findsNothing);
  });

  testWidgets('dragging an event commits the snapped time', (tester) async {
    final calendarCubit = CalendarCubit();
    final nodeCubit = NodeCubit();
    final settingsCubit = SettingsCubit();
    final feedCubit = FeedCubit(
      calendarCubit: calendarCubit,
      nodeCubit: nodeCubit,
      icalService: IcalService(),
      googleService: MockGoogleService(),
      proxyBase: () => '',
    );
    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day, 10);
    final original = PlannerEvent(
      id: 'evt:drag1',
      subject: 'Drag Me',
      start: dayStart,
      end: dayStart.add(const Duration(hours: 1)),
    );
    calendarCubit.addEvent(original);

    await pumpCalendar(
      tester,
      calendarCubit: calendarCubit,
      feedCubit: feedCubit,
      settingsCubit: settingsCubit,
    );

    final eventFinder = find.text('Drag Me', findRichText: true);
    expect(eventFinder, findsWidgets);
    final center = tester.getCenter(eventFinder.first);

    final gesture = await tester.startGesture(center);
    await tester.pump(); // flush the pointer-down so the timer starts now
    await tester.pump(
      const Duration(milliseconds: 600),
    ); // hold past the long-press timeout
    await gesture.moveTo(center + const Offset(0, 120));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final moved = calendarCubit.byId('evt:drag1')!;
    expect(moved.start.isAfter(original.start), isTrue,
        reason: 'drop should move the event later, got ${moved.start}');
    expect(moved.start.minute % 15, 0,
        reason: 'drop should snap to 15 minutes, got ${moved.start}');
    expect(
      moved.end.difference(moved.start),
      const Duration(hours: 1),
      reason: 'drag should preserve duration',
    );
  });
}
