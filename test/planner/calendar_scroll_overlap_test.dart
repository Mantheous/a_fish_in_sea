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

// Guard-only regression coverage for issue #15 (Refs #15, leaves it open):
// in Day/Week view, wheel-scrolling down over a column with several
// overlapping 9:00-10:00 events painted one tall blank teal block (roughly
// 6:00 -> 10:00) hiding every 9:00 tile on the live web build.
// Limit stated explicitly: synthetic PointerScrollEvents in a widget test
// cannot reproduce that web-only paint artifact (it needs a real
// wheel/trackpad on the live Tailnet build), so a passing run here does NOT
// prove the web bug fixed — the ux-walk must re-check Day/Week wheel-scroll
// with a real wheel. What this pins is OUR side of the contract: after
// scrolling, every overlap tile must keep its ~1-hour geometry (no tile may
// balloon to a multi-hour span), stay findable with its subject text, and no
// tall textless block may occlude the 9:00 tiles.
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

  Rect tileRect(WidgetTester tester, String id) =>
      tester.getRect(find.byKey(ValueKey('tile:$id'), skipOffstage: false));

  double hourHeight(WidgetTester tester) {
    final heights = [
      for (var i = 0; i < 8; i++) tileSize(tester, 'evt:overlap-$i').height,
    ];
    heights.sort();
    return heights[heights.length ~/ 2];
  }

  /// Fails if a tall textless block occludes the 9:00 tiles — the shape of
  /// the reported artifact (full-width teal, ~4h, no subject text). Scans
  /// solid-fill Containers (both our builder tiles and Syncfusion defaults
  /// surface this way via getColor): any opaque box taller than 2x the hour
  /// that overlaps a 9:00 tile but holds no Text is the bug, whether it is a
  /// ballooned tile or a sibling overlay. Transparent layout boxes are
  /// ignored (they overlap everything by construction).
  void expectNoTextlessOverlay(WidgetTester tester, double hour) {
    final tileRects = [
      for (var i = 0; i < 8; i++) tileRect(tester, 'evt:overlap-$i'),
    ];
    final threshold = hour * 2;
    for (final element in tester.elementList(find.byType(Container))) {
      final widget = element.widget as Container;
      final Color? color = widget.color ??
          (widget.decoration is BoxDecoration
              ? (widget.decoration as BoxDecoration).color
              : null);
      if (color == null || color.a != 1.0) continue;
      if (color == Colors.white) continue;
      late final Rect rect;
      try {
        rect = tester.getRect(
          find.byElementPredicate((e) => identical(e, element)),
        );
      } catch (_) {
        continue;
      }
      if (rect.height <= threshold) continue;
      final overlaps =
          tileRects.any((tile) => tile.overlaps(rect));
      if (!overlaps) continue;
      final hasText = find
          .descendant(
            of: find.byElementPredicate((e) => identical(e, element)),
            matching: find.byType(Text),
          )
          .evaluate()
          .isNotEmpty;
      expect(
        hasText,
        isTrue,
        reason: 'textless ${rect.height.toStringAsFixed(0)}px block '
            '($color) occludes the 9:00 tiles (hour=$hour)',
      );
    }
  }

  void expectSaneOverlapTiles(WidgetTester tester, double hour) {
    for (var i = 0; i < 8; i++) {
      final size = tileSize(tester, 'evt:overlap-$i');
      // A 1-hour tile must never balloon into a multi-hour block: the
      // reported artifact spanned ~4 hours, so anything past 2x is a fail.
      // Uses the pre-scroll hour baseline so a uniform balloon of all 8
      // tiles cannot hide behind its own median.
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
    // Ratio anchor against the 8-hour Dentist tile: if every overlap tile
    // ballooned uniformly, the per-tile 2x check above would still pass
    // against a ballooned median, but Dentist (unaffected) would then be
    // only ~2x the median instead of ~8x.
    final dentistHeight = tileSize(tester, 'evt:dentist').height;
    expect(
      dentistHeight,
      greaterThan(hour * 4),
      reason: 'Dentist 8h tile ($dentistHeight) must dwarf the 1h '
          'median ($hour); otherwise the overlap tiles ballooned uniformly',
    );
    expectNoTextlessOverlay(tester, hour);
  }

  Future<void> scrollGridDown(
    WidgetTester tester, {
    required double hour,
  }) async {
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
      // Check every frame while the 9:00 tiles are still visible: the final
      // resting state scrolls them offscreen (no onscreen overlay could
      // overlap them there), so only per-frame checks can catch a block
      // that appears mid-scroll.
      expectSaneOverlapTiles(tester, hour);
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

      await scrollGridDown(tester, hour: hour);
      expectSaneOverlapTiles(tester, hour);
    });
  }
}
