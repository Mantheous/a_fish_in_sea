import 'package:flutter/material.dart';

import '../service/calendar_report.dart';
import 'calendar_grid_tracker.dart';
import 'calendar_report_lane.dart';

/// Paints each visible day's report column in the trailing half of its day
/// cell, on top of the plan calendar.
///
/// The overlay is passive: it has no scrollable, no controller and no
/// navigation of its own. It follows the plan grid's scroll offset and
/// clips to the grid's viewport, so it can never drift from the plans
/// beside it, and empty lane space lets every gesture fall through to the
/// calendar underneath.
///
/// Scrolling only *translates* the lanes inside the clip. The chips are laid
/// out once for the whole day and then move as one cached layer; rebuilding
/// every chip per scroll tick used to cost 10–20ms a frame on a week with a
/// handful of reports per day, which read as the calendar freezing while
/// scrolling.
class ReportLaneOverlay extends StatelessWidget {
  const ReportLaneOverlay({
    super.key,
    required this.tracker,
    required this.width,
    required this.days,
    required this.startHour,
    required this.endHour,
    required this.pixelsPerMinute,
    required this.snapMinutes,
    required this.timeRulerWidth,
    required this.isRtl,
    required this.blocksForDay,
    required this.colorFor,
    required this.selectedId,
    required this.onTap,
    required this.onIntervalChanged,
    this.onRecord,
    this.onDeleted,
  });

  final PlanGridTracker tracker;

  /// Width of the calendar area the overlay fills.
  final double width;

  /// The days the calendar shows, in display order.
  final List<DateTime> days;

  /// First and last hour the grid renders, e.g. 6 and 24.
  final double startHour;
  final double endHour;

  /// Vertical scale of the plan grid.
  final double pixelsPerMinute;

  final int snapMinutes;
  final double timeRulerWidth;
  final bool isRtl;
  final List<ReportBlock> Function(DateTime day) blocksForDay;
  final Color Function(ReportBlock block) colorFor;
  final String? selectedId;
  final ValueChanged<ReportBlock> onTap;
  final ReportIntervalChanged? onIntervalChanged;

  /// Starts another recording for a report's task; null hides the chip's
  /// play button.
  final ValueChanged<ReportBlock>? onRecord;

  /// Deletes one recorded run without touching the task's other runs.
  final ValueChanged<ReportBlock>? onDeleted;

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) return const SizedBox.shrink();
    // Only the viewport matters here: it sets the clip and the lane origin.
    // It is stable while the grid scrolls, so this builder stays idle then.
    return ListenableBuilder(
      listenable: Listenable.merge([
        tracker.viewportLocalListenable,
        tracker.contentHeightListenable,
      ]),
      builder: (context, _) {
        final viewport = tracker.viewportLocal;
        // The grid's rect in this overlay's own coordinate space. Null
        // until the calendar has laid its time grid out once.
        if (viewport == null) return const SizedBox.shrink();
        final gridWidth = width - timeRulerWidth;
        if (gridWidth <= 0 || viewport.height <= 0) {
          return const SizedBox.shrink();
        }
        final cellWidth = gridWidth / days.length;
        final minutes = (endHour - startHour) * 60;
        final gridHeight =
            tracker.contentHeightListenable.value ?? minutes * pixelsPerMinute;
        // Only the vertical band matters: the overlay spans the calendar
        // area itself, so a sideways offset from a neighbouring calendar
        // page can never move the lanes.
        final band = Rect.fromLTWH(0, viewport.top, width, viewport.height);
        final lanes = <Widget>[
          for (var index = 0; index < days.length; index++)
            Positioned(
              left: _laneLeft(index, cellWidth),
              top: 0,
              width: cellWidth / 2,
              height: gridHeight,
              child: ReportLaneView(
                key: ValueKey('report-lane:${days[index]}'),
                blocks: blocksForDay(days[index]),
                day: days[index],
                startHour: startHour,
                endHour: endHour,
                pixelsPerMinute: gridHeight / minutes,
                colorFor: colorFor,
                selectedId: selectedId,
                snapMinutes: snapMinutes,
                isRtl: isRtl,
                onTap: onTap,
                onIntervalChanged: onIntervalChanged,
                onRecord: onRecord,
                onDeleted: onDeleted,
              ),
            ),
        ];
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fromRect(
              rect: band,
              child: ClipRect(
                // Scrolling only moves this layer; the chips inside are
                // built once per day and reused for every frame of the
                // scroll. The moving layer is a whole day tall and hangs off
                // the top of the clip, so chips keep working at any offset.
                child: AnimatedBuilder(
                  animation: tracker,
                  child: RepaintBoundary(
                    // A wheel over a chip used to die there: the chip takes
                    // the pointer, and the plan grid's scrollable is not in
                    // its hit path. Forward it to the grid like a plan tile
                    // does, so the whole calendar area scrolls as one.
                    child: Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerSignal: tracker.onPlanPointerSignal,
                      child: GestureDetector(
                        onVerticalDragStart: tracker.onPlanVerticalDragStart,
                        onVerticalDragUpdate: tracker.onPlanVerticalDrag,
                        onVerticalDragEnd: tracker.onPlanVerticalDragEnd,
                        onVerticalDragCancel: tracker.onPlanVerticalDragCancel,
                        child: Stack(clipBehavior: Clip.none, children: lanes),
                      ),
                    ),
                  ),
                  builder: (context, child) => Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        left: 0,
                        top: -tracker.scrollOffset,
                        width: width,
                        height: gridHeight,
                        child: child!,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Left edge of a day's report half, in the lane stack's coordinates.
  double _laneLeft(int index, double cellWidth) {
    final column = isRtl ? days.length - 1 - index : index;
    final cellLeft = (isRtl ? 0.0 : timeRulerWidth) + column * cellWidth;
    return isRtl ? cellLeft : cellLeft + cellWidth / 2;
  }
}
