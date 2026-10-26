import 'package:a_fish_in_sea/planner/service/calendar_report.dart';
import 'package:a_fish_in_sea/planner/view/calendar_grid_tracker.dart';
import 'package:a_fish_in_sea/planner/view/calendar_report_lane.dart';
import 'package:a_fish_in_sea/planner/view/report_lane_overlay.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scrolling must move the report chips, not rebuild them.
///
/// The Plan + Report lane used to rebuild every chip on every scroll tick.
/// A week with a handful of reports per day spent 10–20ms per frame doing
/// that, which showed up as the calendar stalling while the user scrolled.
/// These tests pin the contract: the lane widget survives a scroll untouched
/// and only its offset changes, and the tracker's viewport notifiers stay
/// quiet during scrolling (they are the resize path).
ReportBlock _block(int index) {
  final start = DateTime(2026, 10, 20, 9).add(Duration(minutes: index * 30));
  return ReportBlock(
    displayId: 'report:$index',
    title: 'Report $index',
    start: start,
    end: start.add(const Duration(minutes: 25)),
    kind: ReportBlockKind.accepted,
    recordable: true,
  );
}

void main() {
  testWidgets('a scroll tick moves report chips without rebuilding them', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = ScrollController();
    addTearDown(controller.dispose);
    final anchor = GlobalKey();
    final tracker = PlanGridTracker(
      isMounted: () => true,
      timeGridViewportThreshold: 60,
      anchorKey: anchor,
    );
    addTearDown(tracker.dispose);
    final days = [for (var d = 0; d < 7; d++) DateTime(2026, 10, 20 + d)];
    final blocks = <DateTime, List<ReportBlock>>{
      for (final day in days) day: [for (var i = 0; i < 4; i++) _block(i)],
    };

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1200,
          height: 400,
          child: Stack(
            key: anchor,
            children: [
              // Stands in for SfCalendar's time grid: the scrollable the
              // tracker measures and listens to.
              Positioned.fill(
                child: SingleChildScrollView(
                  controller: controller,
                  child: const SizedBox(width: 1200, height: 600),
                ),
              ),
              // The overlay is a sibling, not part of the scrolled content —
              // exactly how the page stacks it over the calendar.
              Positioned.fill(
                child: ReportLaneOverlay(
                  tracker: tracker,
                  width: 1200,
                  days: days,
                  startHour: 6,
                  endHour: 24,
                  pixelsPerMinute: 80 / 60,
                  snapMinutes: 5,
                  timeRulerWidth: 70,
                  isRtl: false,
                  blocksForDay: (day) => blocks[day] ?? const <ReportBlock>[],
                  colorFor: (_) => Colors.blue,
                  selectedId: null,
                  onTap: (_) {},
                  onIntervalChanged: (_, __, ___) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    tracker.discover(tester.element(find.byType(Stack).first));
    tracker.refreshViewport();
    await tester.pump();

    final laneFinder = find.byType(ReportLaneView);
    expect(laneFinder, findsNWidgets(7));
    final chipFinder = find.byKey(const ValueKey('report-chip:report:0'));
    expect(chipFinder, findsNWidgets(7));
    final laneBefore = tester.widget<ReportLaneView>(laneFinder.first);
    final chipBefore = tester.getRect(chipFinder.first);

    var viewportNotifies = 0;
    tracker.viewportLocalListenable.addListener(() => viewportNotifies++);

    controller.jumpTo(80);
    await tester.pump();

    // Chips follow the grid...
    final chipAfter = tester.getRect(chipFinder.first);
    expect(chipAfter.top, closeTo(chipBefore.top - 80, 0.5));
    // ...by moving the cached lane, not by rebuilding it per frame.
    expect(
      identical(tester.widget<ReportLaneView>(laneFinder.first), laneBefore),
      isTrue,
      reason: 'the lane must not rebuild on a scroll tick',
    );
    expect(
      viewportNotifies,
      0,
      reason: 'scrolling never changes the viewport, only the offset',
    );

    // Measuring the same geometry again is not a change.
    tracker.refreshViewport();
    expect(viewportNotifies, 0);
  });

  testWidgets('the wheel scrolls the plan grid even over a report chip', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final anchor = GlobalKey();
    final tracker = PlanGridTracker(
      isMounted: () => true,
      timeGridViewportThreshold: 60,
      anchorKey: anchor,
    );
    addTearDown(tracker.dispose);
    final day = DateTime(2026, 10, 20);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1200,
          height: 400,
          child: Stack(
            key: anchor,
            children: [
              Positioned.fill(
                child: SingleChildScrollView(
                  controller: controller,
                  child: const SizedBox(width: 1200, height: 600),
                ),
              ),
              Positioned.fill(
                child: ReportLaneOverlay(
                  tracker: tracker,
                  width: 1200,
                  days: [day],
                  startHour: 6,
                  endHour: 24,
                  pixelsPerMinute: 80 / 60,
                  snapMinutes: 5,
                  timeRulerWidth: 70,
                  isRtl: false,
                  blocksForDay: (_) => [_block(0)],
                  colorFor: (_) => Colors.blue,
                  selectedId: null,
                  onTap: (_) {},
                  onIntervalChanged: (_, __, ___) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    tracker.discover(tester.element(find.byType(Stack).first));
    tracker.refreshViewport();
    await tester.pump();

    final chip = find.byKey(const ValueKey('report-chip:report:0'));
    expect(chip, findsOneWidget);
    expect(controller.offset, 0);
    tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: tester.getCenter(chip),
        scrollDelta: const Offset(0, 60),
      ),
    );
    await tester.pump();
    expect(
      controller.offset,
      60,
      reason: 'the chip must forward the wheel to the plan grid',
    );
  });

  testWidgets('resizing the grid publishes a new viewport', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final anchor = GlobalKey();
    final tracker = PlanGridTracker(
      isMounted: () => true,
      timeGridViewportThreshold: 60,
      anchorKey: anchor,
    );
    addTearDown(tracker.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1200,
          height: 400,
          child: Stack(
            key: anchor,
            children: [
              Positioned.fill(
                child: SingleChildScrollView(
                  child: const SizedBox(width: 1200, height: 600),
                ),
              ),
              Positioned.fill(
                child: ReportLaneOverlay(
                  tracker: tracker,
                  width: 1200,
                  days: [DateTime(2026, 10, 20)],
                  startHour: 6,
                  endHour: 24,
                  pixelsPerMinute: 80 / 60,
                  snapMinutes: 5,
                  timeRulerWidth: 70,
                  isRtl: false,
                  blocksForDay: (_) => const <ReportBlock>[],
                  colorFor: (_) => Colors.blue,
                  selectedId: null,
                  onTap: (_) {},
                  onIntervalChanged: (_, __, ___) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    tracker.discover(tester.element(find.byType(Stack).first));
    tracker.refreshViewport();
    await tester.pump();
    expect(tracker.viewportLocal, isNotNull);

    var notifies = 0;
    tracker.viewportLocalListenable.addListener(() => notifies++);
    tracker.refreshViewport();
    expect(notifies, 0);

    await tester.binding.setSurfaceSize(const Size(900, 320));
    await tester.pump();
    tracker.refreshViewport();
    expect(
      notifies,
      greaterThan(0),
      reason: 'the clip has to follow a resized viewport',
    );
    expect(tracker.viewportLocal!.height, lessThan(600));
  });
}
