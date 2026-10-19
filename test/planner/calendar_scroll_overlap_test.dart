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
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

class MockStorage extends Mock implements Storage {}

class MockGoogleService extends Mock implements GoogleCalendarService {}

// Regression coverage for issue #15: in Day/Week view, wheel-scrolling down
// over a column with several overlapping 9:00-10:00 events painted one tall
// blank teal block (roughly 6:00 -> 10:00) hiding every 9:00 tile. The block
// is a Syncfusion layout artifact outside the builder's control, so this
// test pins OUR side of the contract: after scrolling, every overlap tile
// must keep its ~1-hour geometry (no tile may balloon to a multi-hour span)
// and stay findable with its subject text.
void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  Future<void> pumpOverlapGrid(
    WidgetTester tester, {
    required CalendarView view,
  }) async {
    final calendarCubit = CalendarCubit();
    final nodeCubit = NodeCubit();
    final settingsCubit = SettingsCubit();
    settingsCubit.setDefaultCalendarView(view);
    final feedCubit = FeedCubit(
      calendarCubit: calendarCubit,
      nodeCubit: nodeCubit,
      icalService: IcalService(),
      googleService: MockGoogleService(),
      proxyBase: () => '',
    );
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    for (var i = 0; i < 8; i++) {
      calendarCubit.addEvent(PlannerEvent(
        id: 'evt:overlap-$i',
        subject: 'Overlap $i',
        start: DateTime(day.year, day.month, day.day, 9),
        end: DateTime(day.year, day.month, day.day, 10),
      ));
    }
    calendarCubit.addEvent(PlannerEvent(
      id: 'evt:dentist',
      subject: 'Dentist',
      start: DateTime(day.year, day.month, day.day, 14),
      end: DateTime(day.year, day.month, day.day, 22),
    ));

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

  Size tileSize(WidgetTester tester, String id) =>
      tester.getSize(find.byKey(ValueKey('tile:$id'), skipOffstage: false));

  double hourHeight(WidgetTester tester) {
    final heights = [
      for (var i = 0; i < 8; i++) tileSize(tester, 'evt:overlap-$i').height,
    ];
    heights.sort();
    return heights[heights.length ~/ 2];
  }

  void expectSaneOverlapTiles(WidgetTester tester, double hour) {
    for (var i = 0; i < 8; i++) {
      final size = tileSize(tester, 'evt:overlap-$i');
      // A 1-hour tile must never balloon into a multi-hour block: the
      // reported artifact spanned ~4 hours, so anything past 2x is a fail.
      expect(
        size.height,
        lessThan(hour * 2),
        reason: 'overlap tile $i grew to ${size.height} (hour=$hour)',
      );
      expect(size.height, greaterThan(0), reason: 'overlap tile $i collapsed');
      expect(find.text('Overlap $i'), findsWidgets,
          reason: 'overlap tile $i lost its subject text');
    }
    expect(find.text('Dentist'), findsWidgets,
        reason: 'unrelated full-day tile must survive the scroll too');
  }

  Future<void> scrollGridDown(WidgetTester tester) async {
    final center = tester.getCenter(find.byKey(const Key('plan-calendar')));
    final before = tester.getTopLeft(
      find.byKey(const ValueKey('tile:evt:overlap-0'), skipOffstage: false),
    );
    for (var i = 0; i < 6; i++) {
      tester.binding.handlePointerEvent(PointerScrollEvent(
        position: center,
        scrollDelta: const Offset(0, 150),
      ));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final after = tester.getTopLeft(
      find.byKey(const ValueKey('tile:evt:overlap-0'), skipOffstage: false),
    );
    expect(after.dy, lessThan(before.dy),
        reason: 'wheel events must actually move the grid');
    await tester.pumpAndSettle();
  }

  for (final view in [CalendarView.day, CalendarView.week]) {
    testWidgets(
        'scrolling the ${view.name} grid keeps overlap tiles at 1-hour geometry',
        (tester) async {
      await pumpOverlapGrid(tester, view: view);

      final hour = hourHeight(tester);
      expect(hour, greaterThan(0));
      expectSaneOverlapTiles(tester, hour);

      await scrollGridDown(tester);
      expectSaneOverlapTiles(tester, hour);
    });
  }
}
