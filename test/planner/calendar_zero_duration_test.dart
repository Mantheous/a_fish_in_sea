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

/// Regression test: a zero-duration event (start == end — an iCal import
/// with no DTEND/DURATION, or a hand-edited span) used to lay out a
/// 0px-tall tile. It was invisible and untappable on the day/week grid
/// while still appearing in lists, the month agenda and report blocks.
/// The tile now floors at the app's minimum event span (15 minutes), and
/// tapping it opens its details like any other event.
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
  Finder eventTile() => find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).borderRadius ==
                BorderRadius.circular(6) &&
            w.child is LayoutBuilder,
      );

  Finder handle(String label) => find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == label,
      );

  testWidgets('zero-duration event renders a visible tile', (tester) async {
    await pumpCalendar(
      tester,
      events: [eventAt('evt:zero1', 'Zero One', 10, 0)],
    );
    expect(eventTile(), findsOneWidget);
    final height = tester.getSize(eventTile()).height;
    expect(
      height,
      greaterThan(0),
      reason: 'a zero-duration tile must not lay out 0px tall',
    );
    expect(
      height,
      lessThan(30),
      reason: 'the floor should read like a 15-min block, not a full hour',
    );
  });

  testWidgets('zero-duration tile matches a 15-minute tile height', (
    tester,
  ) async {
    await pumpCalendar(
      tester,
      events: [
        eventAt('evt:zero2', 'Zero Two', 10, 0),
        eventAt('evt:quarter', 'Quarter', 12, 15),
      ],
    );
    final tiles = eventTile().evaluate().toList();
    expect(tiles.length, 2);
    final heights = [
      for (final tile in tiles)
        (tile.renderObject! as RenderBox).size.height,
    ];
    expect(heights[0], closeTo(heights[1], 1.5));
  });

  testWidgets('tapping a zero-duration tile opens its details', (tester) async {
    await pumpCalendar(
      tester,
      events: [eventAt('evt:zero3', 'Zero Three', 10, 0)],
    );
    // Near the tile's bottom edge: a 0-height tile would miss the tap
    // (only its boundary line could be hit), the floored tile takes it.
    final size = tester.getSize(eventTile());
    final topLeft = tester.getTopLeft(eventTile());
    await tester.tapAt(topLeft + Offset(size.width / 2, size.height - 3));
    await tester.pumpAndSettle();
    expect(find.text('Event details'), findsOneWidget);
    expect(find.text('Zero Three'), findsWidgets);
  });

  testWidgets('zero-duration resize handles scale like the grid', (
    tester,
  ) async {
    final calendarCubit = await pumpCalendar(
      tester,
      events: [eventAt('evt:zero4', 'Zero Four', 10, 0)],
    );
    await tester.tapAt(tester.getCenter(eventTile()));
    await tester.pumpAndSettle();
    expect(handle('Drag to change end time'), findsOneWidget);

    await tester.drag(handle('Drag to change end time'), const Offset(0, 40));
    await tester.pumpAndSettle();
    final updated = calendarCubit.byId('evt:zero4')!;
    final grown = updated.end.difference(updated.start);
    // 40px at the grid's ~1.3px/min is ~30 min (snap-rounded); the old
    // 60-minute drag fallback turned the same gesture into a 2-hour block.
    expect(
      grown.inMinutes,
      inInclusiveRange(15, 60),
      reason: 'zero-duration handle drag should follow the grid scale',
    );
  });
}
