import 'package:flutter/material.dart';

/// Pairs the plan and report tracks inside each day cell while leaving the
/// calendar's own headers and time grid in one shared position.
class CalendarReportLayout extends StatefulWidget {
  const CalendarReportLayout({
    super.key,
    required this.plans,
    required this.reports,
    required this.reportTopInset,
    required this.dayCount,
    required this.timeRulerWidth,
    required this.isRtl,
  });

  final Widget plans;
  final Widget? reports;
  final double reportTopInset;
  final int dayCount;
  final double timeRulerWidth;
  final bool isRtl;

  @override
  State<CalendarReportLayout> createState() => _CalendarReportLayoutState();
}

class _CalendarReportLayoutState extends State<CalendarReportLayout> {
  late final OverlayEntry _calendarEntry = OverlayEntry(
    builder: _calendarStack,
  );

  @override
  void didUpdateWidget(CalendarReportLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    _calendarEntry.markNeedsBuild();
  }

  @override
  Widget build(BuildContext context) =>
      Overlay(initialEntries: [_calendarEntry], clipBehavior: Clip.hardEdge);

  Widget _calendarStack(BuildContext context) {
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned.fill(child: widget.plans),
        if (widget.reports != null)
          Positioned(
            top: widget.reportTopInset,
            left: 0,
            right: 0,
            bottom: 0,
            child: ClipPath(
              clipper: _ReportColumnClipper(
                dayCount: widget.dayCount,
                timeRulerWidth: widget.timeRulerWidth,
                isRtl: widget.isRtl,
              ),
              child: widget.reports!,
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _calendarEntry
      ..remove()
      ..dispose();
    super.dispose();
  }
}

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
  VoidCallback? onTap,
  GestureLongPressStartCallback? onLongPressStart,
  GestureLongPressMoveUpdateCallback? onLongPressMoveUpdate,
  GestureLongPressEndCallback? onLongPressEnd,
  VoidCallback? onLongPressCancel,
}) {
  if (visibleDays.isEmpty || !calendarWidth.isFinite || bounds.width <= 0) {
    return child;
  }
  final dayIndex = visibleDays.indexWhere((visible) => _sameDay(visible, day));
  if (dayIndex < 0) return child;

  final cellWidth = (calendarWidth - timeRulerWidth) / visibleDays.length;
  if (cellWidth <= 0 || bounds.width > cellWidth + 2) {
    // A multi-day appointment can't be narrowed safely as one tile; the
    // report half still masks its trailing half in the paired calendar.
    return child;
  }
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
    onTap: onTap,
    onLongPressStart: onLongPressStart,
    onLongPressMoveUpdate: onLongPressMoveUpdate,
    onLongPressEnd: onLongPressEnd,
    onLongPressCancel: onLongPressCancel,
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
    required this.child,
    required this.onTap,
    required this.onLongPressStart,
    required this.onLongPressMoveUpdate,
    required this.onLongPressEnd,
    required this.onLongPressCancel,
  });

  final LayerLink link;
  final double shift;
  final double width;
  final double height;
  final Widget child;
  final VoidCallback? onTap;
  final GestureLongPressStartCallback? onLongPressStart;
  final GestureLongPressMoveUpdateCallback? onLongPressMoveUpdate;
  final GestureLongPressEndCallback? onLongPressEnd;
  final VoidCallback? onLongPressCancel;

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
        overlayChildBuilder: (context) => Positioned(
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
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onTap,
                onLongPressStart: widget.onLongPressStart,
                onLongPressMoveUpdate: widget.onLongPressMoveUpdate,
                onLongPressEnd: widget.onLongPressEnd,
                onLongPressCancel: widget.onLongPressCancel,
                child: widget.child,
              ),
            ),
          ),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _ReportColumnClipper extends CustomClipper<Path> {
  const _ReportColumnClipper({
    required this.dayCount,
    required this.timeRulerWidth,
    required this.isRtl,
  });

  final int dayCount;
  final double timeRulerWidth;
  final bool isRtl;

  @override
  Path getClip(Size size) {
    final gridWidth = size.width - timeRulerWidth;
    if (dayCount <= 0 || gridWidth <= 0) return Path();
    final cellWidth = gridWidth / dayCount;
    final path = Path();
    for (var index = 0; index < dayCount; index++) {
      final column = isRtl ? dayCount - 1 - index : index;
      final cellLeft = (isRtl ? 0.0 : timeRulerWidth) + column * cellWidth;
      path.addRect(
        Rect.fromLTWH(
          isRtl ? cellLeft : cellLeft + cellWidth / 2,
          0,
          cellWidth / 2,
          size.height,
        ),
      );
    }
    return path;
  }

  @override
  bool shouldReclip(_ReportColumnClipper oldClipper) =>
      dayCount != oldClipper.dayCount ||
      timeRulerWidth != oldClipper.timeRulerWidth ||
      isRtl != oldClipper.isRtl;
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
