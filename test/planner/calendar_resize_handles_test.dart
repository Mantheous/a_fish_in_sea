import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_visibility_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
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

/// Regression test: shrinking an event to ~15 minutes used to make its
/// resize handles disappear (they were gated on a 58px tile height), so
/// the event could never be dragged long again via the calendar.
void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  Future<CalendarCubit> pumpCalendar(
    WidgetTester tester, {
    required List<PlannerEvent> events,
  }) async {
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
    for (final event in events) {
      calendarCubit.addEvent(event);
    }
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
    return calendarCubit;
  }

  PlannerEvent eventAt(String id, String subject, int hour, int minutes) {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, hour);
    return PlannerEvent(
      id: id,
      subject: subject,
      start: start,
      end: start.add(Duration(minutes: minutes)),
    );
  }

  /// The event tile: rounded-6 container wrapping the LayoutBuilder body.
  /// (A 15-minute tile is too short to render its title text, so the tile
  /// itself — not its label — is the tap target.)
  Finder eventTile() => find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).borderRadius ==
                BorderRadius.circular(6) &&
            w.child is LayoutBuilder,
      );

  /// Resize-handle circles are labeled for semantics; matching the widget
  /// (not the semantics tree) keeps the test independent of a11y flags.
  Finder handle(String label) => find.byWidgetPredicate(
        (w) =>
            w is Semantics && w.properties.label == label,
      );

  testWidgets('short selected event keeps its resize handles', (tester) async {
    final calendarCubit = await pumpCalendar(
      tester,
      events: [eventAt('evt:short1', 'Short One', 10, 15)],
    );
    expect(eventTile(), findsOneWidget);

    // Nothing selected yet: no handles anywhere.
    expect(handle('Drag to change start time'), findsNothing);
    expect(handle('Drag to change end time'), findsNothing);

    // Select the 15-minute event: both handles must appear even though
    // the tile is far shorter than a full-size grab pair.
    await tester.tapAt(tester.getCenter(eventTile()));
    await tester.pumpAndSettle();
    expect(find.text('Event details'), findsOneWidget);
    expect(
      handle('Drag to change start time'),
      findsOneWidget,
      reason: 'top handle vanished on a 15-min tile',
    );
    expect(
      handle('Drag to change end time'),
      findsOneWidget,
      reason: 'bottom handle vanished on a 15-min tile',
    );

    // Dragging the bottom handle longer keeps the event selected with
    // handles still attached.
    await tester.drag(
      handle('Drag to change end time'),
      const Offset(0, 80),
    );
    await tester.pumpAndSettle();
    final updated = calendarCubit.byId('evt:short1')!;
    expect(
      updated.end.difference(updated.start) > const Duration(minutes: 15),
      isTrue,
      reason: 'bottom-handle drag should lengthen the event',
    );
    expect(handle('Drag to change end time'), findsOneWidget);
  });

  testWidgets('hour-long selected event still shows handles', (tester) async {
    await pumpCalendar(
      tester,
      events: [eventAt('evt:long1', 'Long One', 12, 60)],
    );

    await tester.tap(find.text('Long One', findRichText: true).first);
    await tester.pumpAndSettle();
    expect(find.text('Event details'), findsOneWidget);
    expect(handle('Drag to change start time'), findsOneWidget);
    expect(handle('Drag to change end time'), findsOneWidget);
  });
}
