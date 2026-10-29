import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../common/time/local_date.dart';
import 'calendar_formats.dart';
import 'calendar_grid_tracker.dart';

/// Where a move drag would drop the tile: the day/time it would land on,
/// with the geometry of the grid it is dragging over.
///
/// The ghost is painted beside the calendar instead of moving the real
/// appointment: re-laying out every tile on each pointer sample is what made
/// the drag feel laggy, and rebuilding the dragged tile's subtree mid-drag
/// could cancel the gesture that is moving it.
class PlanDragGhost {
  const PlanDragGhost({
    required this.subject,
    required this.color,
    required this.days,
    required this.day,
    required this.startMinutes,
    required this.durationMinutes,
    required this.cellWidth,
    required this.pixelsPerMinute,
    required this.startHour,
    required this.timeRulerWidth,
    required this.isRtl,
    required this.sideBySide,
  });

  final String subject;
  final Color color;

  /// The visible columns, in display order.
  final List<DateTime> days;

  /// The midnight of the day the tile would land on.
  final DateTime day;

  /// Minutes since midnight of the landing time, already snapped.
  final double startMinutes;
  final double durationMinutes;

  final double cellWidth;
  final double pixelsPerMinute;

  /// First hour the time grid renders, e.g. 6.
  final double startHour;
  final double timeRulerWidth;
  final bool isRtl;

  /// True in Plan + Report: plan tiles take the leading half of each day.
  final bool sideBySide;

  DateTime get start => DateTime(
    day.year,
    day.month,
    day.day,
  ).add(Duration(minutes: startMinutes.round()));

  DateTime get end => start.add(Duration(minutes: durationMinutes.round()));
}

/// Paints [ghost] over the time grid, clipped to its viewport and glued to
/// its scroll offset. Pointer-transparent: the drag keeps flowing to the
/// tile recognizer that owns it.
class PlanDragGhostLayer extends StatelessWidget {
  const PlanDragGhostLayer({
    super.key,
    required this.ghost,
    required this.tracker,
  });

  final ValueListenable<PlanDragGhost?> ghost;
  final PlanGridTracker tracker;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlanDragGhost?>(
      valueListenable: ghost,
      builder: (context, value, _) {
        if (value == null) return const SizedBox.shrink();
        // The ghost keeps its slot while the grid auto-scrolls under it.
        return AnimatedBuilder(
          animation: tracker,
          builder: (context, _) => _paint(value),
        );
      },
    );
  }

  Widget _paint(PlanDragGhost value) {
    final viewport = tracker.viewportLocal;
    if (viewport == null || value.days.isEmpty) {
      return const SizedBox.shrink();
    }
    final index = value.days.indexWhere(
      (visible) => isSameLocalDay(visible, value.day),
    );
    if (index < 0) return const SizedBox.shrink();
    final column = value.isRtl ? value.days.length - 1 - index : index;
    final cellLeft =
        (value.isRtl ? 0.0 : value.timeRulerWidth) + column * value.cellWidth;
    final trackLeft = value.sideBySide
        ? (value.isRtl ? cellLeft + value.cellWidth / 2 : cellLeft)
        : cellLeft;
    final trackWidth = value.sideBySide ? value.cellWidth / 2 : value.cellWidth;
    final top =
        viewport.top +
        (value.startMinutes - value.startHour * 60) * value.pixelsPerMinute -
        tracker.scrollOffset;
    final height = math.max(
      value.durationMinutes * value.pixelsPerMinute,
      15 * value.pixelsPerMinute,
    );
    return Positioned.fill(
      child: IgnorePointer(
        child: ClipRect(
          clipper: _GridViewportClipper(viewport),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: trackLeft + 2,
                top: top,
                width: math.max(trackWidth - 4, 1),
                height: math.max(height, 1),
                child: _ghostBlock(value, height),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ghostBlock(PlanDragGhost value, double height) {
    final showTitle = height >= 24;
    final showTime = height >= 40;
    return Opacity(
      key: const ValueKey('plan-drag-ghost'),
      opacity: 0.9,
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
        decoration: BoxDecoration(
          color: value.color,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: ClipRect(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showTitle)
                Text(
                  value.subject,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              if (showTime)
                Text(
                  '${calendarTimeFormat.format(value.start)} – '
                  '${calendarTimeFormat.format(value.end)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GridViewportClipper extends CustomClipper<Rect> {
  const _GridViewportClipper(this.viewport);

  final Rect viewport;

  @override
  Rect getClip(Size size) => viewport.intersect(Offset.zero & size);

  @override
  bool shouldReclip(_GridViewportClipper oldClipper) =>
      viewport != oldClipper.viewport;
}
