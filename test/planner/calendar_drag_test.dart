import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/task_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
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
          BlocProvider(create: (_) => TaskCubit()),
          BlocProvider.value(value: feedCubit),
        ],
        child: const MaterialApp(home: CalendarPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('tapping an event opens the drawer', (tester) async {
    final calendarCubit = CalendarCubit();
    final taskCubit = TaskCubit();
    final settingsCubit = SettingsCubit();
    final feedCubit = FeedCubit(
      calendarCubit: calendarCubit,
      taskCubit: taskCubit,
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
    final taskCubit = TaskCubit();
    final settingsCubit = SettingsCubit();
    final feedCubit = FeedCubit(
      calendarCubit: calendarCubit,
      taskCubit: taskCubit,
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
    final taskCubit = TaskCubit();
    final settingsCubit = SettingsCubit();
    final feedCubit = FeedCubit(
      calendarCubit: calendarCubit,
      taskCubit: taskCubit,
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
