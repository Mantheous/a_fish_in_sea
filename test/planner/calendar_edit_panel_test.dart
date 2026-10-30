import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
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
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

class MockGoogleService extends Mock implements GoogleCalendarService {}

/// Guards issue #218 (blank edit panel): opening Edit from the Calendar day
/// view must always show the entry's current values — or a clear
/// deleted message — never an empty box with only Delete/Cancel/Save.
void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  Future<CalendarCubit> pumpPage(
    WidgetTester tester,
    List<PlannerEvent> events,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
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
    return calendarCubit;
  }

  PlannerEvent timed(String id, String subject, int hour) {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, hour);
    return PlannerEvent(
      id: id,
      subject: subject,
      start: start,
      end: start.add(const Duration(hours: 1)),
    );
  }

  /// Opens Edit for the tile showing [subject] and expects the form with
  /// the entry's current values (title field prefilled, actions present).
  Future<void> expectFilledEdit(
    WidgetTester tester,
    String subject,
  ) async {
    await tester.tap(find.text(subject, findRichText: true).first);
    await tester.pumpAndSettle();
    expect(find.text('Event details'), findsOneWidget);

    final editBtn = find.widgetWithText(TextButton, 'Edit');
    expect(editBtn, findsOneWidget);
    await tester.dragUntilVisible(
      editBtn,
      find.byType(CalendarPage),
      const Offset(0, -100),
    );
    await tester.pumpAndSettle();
    await tester.tap(editBtn);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Edit event'), findsOneWidget);
    // The entry's current values are shown, not a blank box.
    expect(find.text(subject), findsWidgets);
    expect(find.byType(TextField), findsWidgets);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);

    // Back out to the task list for the next entry.
    final back = find.byTooltip('Back to details');
    if (back.evaluate().isNotEmpty) {
      await tester.tap(back);
      await tester.pumpAndSettle();
    }
    final back2 = find.byTooltip('Back to tasks');
    if (back2.evaluate().isNotEmpty) {
      await tester.tap(back2);
      await tester.pumpAndSettle();
    }
  }

  testWidgets('plain entry edit shows its current values', (tester) async {
    await pumpPage(tester, [timed('plain-1', 'Plain entry', 9)]);
    await expectFilledEdit(tester, 'Plain entry');
  });

  testWidgets('repeating entry edit shows its current values', (tester) async {
    final base = timed('series-1', 'Weekly series', 11);
    await pumpPage(tester, [
      PlannerEvent(
        id: base.id,
        subject: base.subject,
        start: base.start,
        end: base.end,
        recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
      ),
    ]);
    await expectFilledEdit(tester, 'Weekly series');
  });

  testWidgets('task-linked block edit shows its current values',
      (tester) async {
    final base = timed('task-1', 'Task block', 13);
    await pumpPage(tester, [
      PlannerEvent(
        id: base.id,
        subject: base.subject,
        start: base.start,
        end: base.end,
        isTask: true,
        taskId: 'node-1',
      ),
    ]);
    await expectFilledEdit(tester, 'Task block');
  });

  testWidgets('edit keeps Delete reachable for a stale place', (tester) async {
    final base = timed('place-1', 'Placed entry', 14);
    await pumpPage(tester, [
      PlannerEvent(
        id: base.id,
        subject: base.subject,
        start: base.start,
        end: base.end,
        placeId: 'missing-place',
      ),
    ]);
    await expectFilledEdit(tester, 'Placed entry');
  });
}
