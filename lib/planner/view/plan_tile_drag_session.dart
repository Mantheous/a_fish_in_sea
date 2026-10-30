import 'dart:async';

import 'package:flutter/material.dart';

import '../../common/time/local_date.dart';
import '../model/event_reschedule.dart';
import '../model/planner_event.dart';
import 'calendar_grid_tracker.dart';

/// One drag of a plan tile: turns global pointer positions into a drop time,
/// keeps the day under the pointer, and auto-scrolls the time grid while the
/// pointer is parked over the time ruler or the top/bottom edge.
///
/// The tile itself only forwards start/update/end; all the geometry lives
/// here so the calendar page stays a view.
class PlanTileDragSession {
  PlanTileDragSession({
    required this.original,
    required List<DateTime> days,
    required Rect? stackRect,
    required double cellWidth,
    required double pixelsPerMinute,
    required bool isRtl,
    required double timeRulerWidth,
    required double startMinutes,
    required double endMinutes,
    required PlanGridTracker tracker,
    this.onDropTimeChanged,
  }) : _days = days,
       _stackRect = stackRect,
       _cellWidth = cellWidth,
       _pixelsPerMinute = pixelsPerMinute,
       _isRtl = isRtl,
       _timeRulerWidth = timeRulerWidth,
       _startMinutes = startMinutes,
       _endMinutes = endMinutes,
       _tracker = tracker,
       _durationMinutes = original.end.isAfter(original.start)
           ? original.end.difference(original.start).inMinutes.toDouble()
           : 60,
       _day = localDay(original.start),
       _dropTime = original.start;

  final PlannerEvent original;
  final PlanGridTracker _tracker;
  final List<DateTime> _days;
  final Rect? _stackRect;
  final double _cellWidth;
  final double _pixelsPerMinute;
  final bool _isRtl;
  final double _timeRulerWidth;
  final double _startMinutes;
  final double _endMinutes;
  final double _durationMinutes;

  Offset? _origin;
  Offset? _pointer;
  DateTime _day;
  DateTime _dropTime;
  double _scrollAtStart = 0;
  Timer? _autoScroll;

  /// Where the tile would be dropped right now.
  DateTime get dropTime => _dropTime;

  /// The event laid out at the current drop slot, snapped exactly like the
  /// committed drop ([shiftEvent]), so the preview and the result match.
  PlannerEvent previewAt(int snapMinutes) =>
      shiftEvent(original, _dropTime, snapMinutes: snapMinutes);

  /// Called whenever [dropTime] changes, including the auto-scroll ticks
  /// where the pointer stands still but the grid moves under it. The owner
  /// uses this to paint the tile at the slot it would land on.
  final ValueChanged<DateTime>? onDropTimeChanged;

  void start(Offset pointer) {
    _origin = pointer;
    _pointer = pointer;
    _dropTime = original.start;
    _scrollAtStart = _tracker.scrollOffset;
    // The pointer is parked over the ruler/edge: scroll even without moves.
    _autoScroll?.cancel();
    _autoScroll = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _tickAutoScroll(),
    );
  }

  void update(Offset pointer) {
    _pointer = pointer;
    _updateDropTime();
  }

  /// Stops the drag, reveals an off-screen drop, and returns the final time.
  DateTime finish() {
    _autoScroll?.cancel();
    _autoScroll = null;
    _revealDropTime();
    return _dropTime;
  }

  void cancel() {
    _autoScroll?.cancel();
    _autoScroll = null;
    _origin = null;
    _pointer = null;
  }

  /// Converts the pointer into a drop time from the *grid* geometry, not the
  /// pointer delta alone: while the grid auto-scrolls under the pointer the
  /// time under the tile changes even when the pointer stands still.
  void _updateDropTime() {
    final origin = _origin;
    final pointer = _pointer;
    if (origin == null || pointer == null) return;
    if (_pixelsPerMinute <= 0 || _cellWidth <= 0 || _days.isEmpty) return;
    final scrollDelta = _tracker.scrollOffset - _scrollAtStart;
    final movedMinutes =
        (pointer.dy - origin.dy + scrollDelta) / _pixelsPerMinute;
    final startMinutes =
        original.start.hour * 60.0 +
        original.start.minute +
        movedMinutes.toDouble();
    final latestStart = _endMinutes - _durationMinutes;
    final targetMinutes = startMinutes.clamp(
      _startMinutes,
      latestStart < _startMinutes ? _startMinutes : latestStart,
    );
    final pointerDay = _dayUnderPointer(pointer);
    if (pointerDay != null) _day = pointerDay;
    final minutes = targetMinutes.round();
    // Grid slots are local clock times, even on 23- or 25-hour days.
    final next = DateTime(
      _day.year,
      _day.month,
      _day.day,
      minutes ~/ 60,
      minutes % 60,
    );
    if (next == _dropTime) return;
    _dropTime = next;
    onDropTimeChanged?.call(next);
  }

  /// Day column the pointer is over, or null when it is over the time ruler
  /// (the vertical auto-scroll handle). Null keeps the last in-grid day
  /// instead of snapping to the first or last column.
  DateTime? _dayUnderPointer(Offset pointer) {
    final stack = _stackRect;
    final left = stack?.left ?? _origin?.dx ?? 0;
    final right = stack?.right ?? left;
    final gridLeft = _isRtl ? left : left + _timeRulerWidth;
    final gridRight = _isRtl ? right - _timeRulerWidth : right;
    if (gridRight - gridLeft <= 0) return null;
    final x = pointer.dx;
    if (_isRtl ? x >= gridRight : x <= gridLeft) return null;
    final column =
        ((_isRtl ? gridRight - x : x - gridLeft) / _cellWidth)
            .floor()
            .clamp(0, _days.length - 1);
    final index = _isRtl ? _days.length - 1 - column : column;
    return _days[index];
  }

  void _tickAutoScroll() {
    final plan = _tracker.position;
    final pointer = _pointer;
    final viewport = _tracker.viewportGlobal;
    if (plan == null || !plan.hasPixels || pointer == null || viewport == null) {
      return;
    }
    final velocity = _autoScrollVelocity(pointer, viewport);
    if (velocity == 0) return;
    final target = (plan.pixels + velocity).clamp(
      plan.minScrollExtent,
      plan.maxScrollExtent,
    );
    if ((target - plan.pixels).abs() < 0.5) return;
    plan.jumpTo(target);
    _updateDropTime();
  }

  /// Pixels per tick to scroll while dragging. Over the time ruler the
  /// pointer's distance from the viewport's middle picks the direction and
  /// speed; near the top/bottom edge the usual edge auto-scroll applies.
  double _autoScrollVelocity(Offset pointer, Rect viewport) {
    final stack = _stackRect;
    if (stack == null) return 0;
    if (pointer.dx < stack.left || pointer.dx > stack.right) return 0;
    final rulerEdge = _isRtl
        ? stack.right - _timeRulerWidth
        : stack.left + _timeRulerWidth;
    final overRuler = _isRtl
        ? pointer.dx >= rulerEdge
        : pointer.dx <= rulerEdge;
    if (overRuler) {
      final mid = viewport.center.dy;
      final deadZone = viewport.height * 0.2;
      final dy = pointer.dy - mid;
      if (dy.abs() <= deadZone) return 0;
      final travel = (viewport.height / 2 - deadZone).clamp(1.0, 1.0e6);
      final depth = ((dy.abs() - deadZone) / travel).clamp(0.0, 1.0);
      return dy.sign * (1.5 + depth * 6.5);
    }
    const edge = 28.0;
    if (pointer.dy < viewport.top + edge) {
      final depth = ((viewport.top + edge - pointer.dy) / edge).clamp(
        0.0,
        1.0,
      );
      return -(1.5 + depth * 6.5);
    }
    if (pointer.dy > viewport.bottom - edge) {
      final depth = ((pointer.dy - (viewport.bottom - edge)) / edge).clamp(
        0.0,
        1.0,
      );
      return 1.5 + depth * 6.5;
    }
    return 0;
  }

  /// Scrolls the grid when a fast drag drops the tile outside the visible
  /// hours, so the block cannot end up hidden above/below the viewport.
  void _revealDropTime() {
    final position = _tracker.position;
    final viewport = _tracker.viewportGlobal;
    if (position == null ||
        !position.hasPixels ||
        viewport == null ||
        _pixelsPerMinute <= 0) {
      return;
    }
    final topInContent =
        (_dropTime.hour * 60 + _dropTime.minute - _startMinutes) *
        _pixelsPerMinute;
    final visibleTop = position.pixels;
    final visibleBottom = visibleTop + viewport.height;
    if (topInContent >= visibleTop + 8 &&
        topInContent <= visibleBottom - 48) {
      return;
    }
    final target = (topInContent - viewport.height * 0.25).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    position.jumpTo(target);
  }
}
