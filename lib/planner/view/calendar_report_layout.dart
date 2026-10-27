import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'calendar_grid_tracker.dart';

/// Compresses a plan appointment into the leading half of its day cell. The
/// appointment's own collision layout is preserved, so overlapping plans
/// still get separate sub-columns within the plan track.
Widget planAppointmentInTrack({
  required Widget child,
  required Rect bounds,
  required DateTime day,
  required List<DateTime> visibleDays,
  required double calendarWidth,
  required double timeRulerWidth,
  required bool isRtl,
  required String eventId,
  required PlanGridTracker? tracker,
  VoidCallback? onTap,
  ValueChanged<PointerSignalEvent>? onPointerSignal,
  GestureDragUpdateCallback? onVerticalDragUpdate,
}) {
  if (visibleDays.isEmpty || !calendarWidth.isFinite || bounds.width <= 0) {
    return child;
  }
  final cellWidth = (calendarWidth - timeRulerWidth) / visibleDays.length;
  if (cellWidth <= 0) return child;
  if (bounds.width > cellWidth + 2) {
    // A multi-day appointment is one tile across several cells, so it
    // can't be narrowed as a whole. Clip it to the plan half of every day
    // it crosses instead: the report half of each day stays clear (and
    // untappable as a plan), exactly as if each day had its own tile.
    return ClipPath(
      clipper: _PlanTrackClipper(
        tileLeft: bounds.left,
        dayCount: visibleDays.length,
        cellWidth: cellWidth,
        timeRulerWidth: timeRulerWidth,
        isRtl: isRtl,
      ),
      child: child,
    );
  }
  final dayIndex = visibleDays.indexWhere((visible) => _sameDay(visible, day));
  if (dayIndex < 0) return child;
  final column = isRtl ? visibleDays.length - 1 - dayIndex : dayIndex;
  final cellLeft = (isRtl ? 0.0 : timeRulerWidth) + column * cellWidth;
  final tileOffset = bounds.left - cellLeft;
  final shift = isRtl
      ? (cellLeft + cellWidth - bounds.left) / 2
      : -tileOffset / 2;
  if (shift.abs() < 0.5) {
    return Align(
      alignment: isRtl ? Alignment.centerRight : Alignment.centerLeft,
      child: SizedBox(width: bounds.width / 2, child: child),
    );
  }
  return _PlanAppointmentOverlay(
    key: ValueKey('plan-report:$eventId'),
    link: LayerLink(),
    shift: shift,
    width: bounds.width / 2,
    height: bounds.height,
    tracker: tracker,
    onTap: onTap,
    onPointerSignal: onPointerSignal,
    onVerticalDragUpdate: onVerticalDragUpdate,
    child: child,
  );
}

class _PlanAppointmentOverlay extends StatefulWidget {
  const _PlanAppointmentOverlay({
    super.key,
    required this.link,
    required this.shift,
    required this.width,
    required this.height,
    required this.tracker,
    required this.child,
    required this.onTap,
    required this.onPointerSignal,
    required this.onVerticalDragUpdate,
  });

  final LayerLink link;
  final double shift;
  final double width;
  final double height;

  /// Source of the grid viewport the shifted tile is clipped to. Listening
  /// to its viewport (not its scroll position) keeps the clip right when the
  /// viewport is first measured or the window/panel resizes, without
  /// rebuilding the tile on every scroll tick.
  final PlanGridTracker? tracker;
  final Widget child;
  final VoidCallback? onTap;
  final ValueChanged<PointerSignalEvent>? onPointerSignal;
  final GestureDragUpdateCallback? onVerticalDragUpdate;

  @override
  State<_PlanAppointmentOverlay> createState() =>
      _PlanAppointmentOverlayState();
}

class _PlanAppointmentOverlayState extends State<_PlanAppointmentOverlay> {
  late final OverlayPortalController _controller = OverlayPortalController()
    ..show();

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: widget.link,
      child: OverlayPortal(
        controller: _controller,
        overlayChildBuilder: (context) {
          return ValueListenableBuilder<Rect?>(
            valueListenable:
                widget.tracker?.viewportGlobalListenable ??
                const AlwaysStoppedAnimation<Rect?>(null),
            builder: (context, viewport, _) => _clippedTile(context),
          );
        },
        child: const SizedBox.expand(),
      ),
    );
  }

  Widget _clippedTile(BuildContext context) {
    final overlayBox = Overlay.of(context).context.findRenderObject();
    final viewport = widget.tracker?.viewportGlobal;
    final Rect? localViewport;
    if (overlayBox is RenderBox && overlayBox.hasSize && viewport != null) {
      final overlayOrigin = overlayBox.localToGlobal(Offset.zero);
      localViewport = viewport.shift(-overlayOrigin);
    } else {
      localViewport = null;
    }
    return Positioned.fill(
      child: ClipRect(
        clipper: _TimeGridViewportClipper(localViewport),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              top: 0,
              child: CompositedTransformFollower(
                link: widget.link,
                showWhenUnlinked: false,
                targetAnchor: Alignment.topLeft,
                followerAnchor: Alignment.topLeft,
                offset: Offset(widget.shift, 0),
                child: SizedBox(
                  width: widget.width,
                  height: widget.height,
                  child: Listener(
                    onPointerSignal: widget.onPointerSignal,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onTap,
                      onVerticalDragUpdate: widget.onVerticalDragUpdate,
                      child: widget.child,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeGridViewportClipper extends CustomClipper<Rect> {
  const _TimeGridViewportClipper(this.viewport);

  final Rect? viewport;

  @override
  Rect getClip(Size size) =>
      viewport?.intersect(Offset.zero & size) ?? (Offset.zero & size);

  @override
  bool shouldReclip(_TimeGridViewportClipper oldClipper) =>
      viewport != oldClipper.viewport;
}

class _PlanTrackClipper extends CustomClipper<Path> {
  const _PlanTrackClipper({
    required this.tileLeft,
    required this.dayCount,
    required this.cellWidth,
    required this.timeRulerWidth,
    required this.isRtl,
  });

  /// Left edge of the appointment tile in calendar coordinates. The clip
  /// path is in the tile's own coordinate space, so every column rect is
  /// shifted by it.
  final double tileLeft;
  final int dayCount;
  final double cellWidth;
  final double timeRulerWidth;
  final bool isRtl;

  @override
  Path getClip(Size size) {
    final path = Path();
    for (var index = 0; index < dayCount; index++) {
      final column = isRtl ? dayCount - 1 - index : index;
      final cellLeft = (isRtl ? 0.0 : timeRulerWidth) + column * cellWidth;
      final trackLeft = isRtl ? cellLeft + cellWidth / 2 : cellLeft;
      path.addRect(
        Rect.fromLTWH(trackLeft - tileLeft, 0, cellWidth / 2, size.height),
      );
    }
    return path;
  }

  @override
  bool shouldReclip(_PlanTrackClipper oldClipper) =>
      tileLeft != oldClipper.tileLeft ||
      dayCount != oldClipper.dayCount ||
      cellWidth != oldClipper.cellWidth ||
      timeRulerWidth != oldClipper.timeRulerWidth ||
      isRtl != oldClipper.isRtl;
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
