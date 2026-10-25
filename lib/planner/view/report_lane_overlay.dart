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
    return AnimatedBuilder(
      animation: tracker,
      builder: (context, _) {
        // The grid's rect in this overlay's own coordinate space. Null
        // until the calendar has laid its time grid out once.
        final viewport = tracker.viewportLocal;
        if (viewport == null) return const SizedBox.shrink();
        final gridWidth = width - timeRulerWidth;
        if (gridWidth <= 0 || viewport.height <= 0) {
          return const SizedBox.shrink();
        }
        final cellWidth = gridWidth / days.length;
        final lanes = <Widget>[];
        for (var index = 0; index < days.length; index++) {
          final day = days[index];
          final column = isRtl ? days.length - 1 - index : index;
          final cellLeft = (isRtl ? 0.0 : timeRulerWidth) + column * cellWidth;
          final left = isRtl ? cellLeft : cellLeft + cellWidth / 2;
          lanes.add(
            Positioned(
              left: left,
              top: viewport.top,
              width: cellWidth / 2,
              height: viewport.height,
              child: ClipRect(
                child: ReportLaneView(
                  key: ValueKey('report-lane:$day'),
                  blocks: blocksForDay(day),
                  day: day,
                  startHour: startHour,
                  endHour: endHour,
                  pixelsPerMinute: pixelsPerMinute,
                  scrollOffset: tracker.scrollOffset,
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
            ),
          );
        }
        return Stack(clipBehavior: Clip.none, children: lanes);
      },
    );
  }
}
