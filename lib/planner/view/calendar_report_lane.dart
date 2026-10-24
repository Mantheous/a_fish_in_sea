import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../service/calendar_report.dart';
import 'report_chip.dart';

// Hoisted: DateFormat construction parses ICU skeletons; the lane can hold
// a dozen chips and this runs on every calendar rebuild.
final _chipTimeFormat = DateFormat('h:mm a');

/// Time label a chip shows, matching the wording the old report tiles used.
String reportChipTimeLabel(ReportBlock block) {
  final range =
      '${_chipTimeFormat.format(block.start)} – ${_chipTimeFormat.format(block.end)}';
  return switch (block.kind) {
    ReportBlockKind.live =>
      'Recording since ${_chipTimeFormat.format(block.start)}',
    ReportBlockKind.timer => '$range · timer',
    ReportBlockKind.accepted => '$range · accepted',
  };
}

/// Called when a drag settles on a new interval for a reported block.
typedef ReportIntervalChanged =
    void Function(ReportBlock block, DateTime start, DateTime end);

/// The report column of one day in the Plan + Report view.
///
/// This is a plain overlay on the single plan calendar, positioned in the
/// trailing half of the day cell by `ReportLaneOverlay`. It is *not* a
/// calendar: it owns no scrollable, no controller and no navigation. The
/// overlay hands it the plan grid's [scrollOffset] and [pixelsPerMinute],
/// so chips move exactly with the plan tiles underneath. Only the chips
/// take pointers — empty lane area lets taps, scrolls and day-changing
/// swipes fall through to the plan calendar.
///
/// A selected (tapped) chip shows the same white resize circles as calendar
/// events; dragging them adjusts the reported interval directly. The drag
/// preview stays local so a chip follows the pointer without re-laying out
/// the plan calendar every frame.
class ReportLaneView extends StatefulWidget {
  const ReportLaneView({
    super.key,
    required this.blocks,
    required this.day,
    required this.startHour,
    required this.endHour,
    required this.colorFor,
    required this.onTap,
    this.selectedId,
    this.snapMinutes = 5,
    this.onIntervalChanged,
    this.isRtl = false,
    this.scrollOffset = 0,
    this.pixelsPerMinute,
  });

  /// The day's report blocks, already ordered by start time.
  final List<ReportBlock> blocks;

  /// Midnight of the day the lane belongs to.
  final DateTime day;

  /// First and last hour the day/week grid renders, e.g. 6 and 24.
  final double startHour;
  final double endHour;

  final Color Function(ReportBlock block) colorFor;
  final ValueChanged<ReportBlock> onTap;

  /// Display id of the report chip the user selected, if any.
  final String? selectedId;

  /// Grid the resize handles snap to.
  final int snapMinutes;

  /// Commits a dragged interval. Live recordings never call this.
  final ReportIntervalChanged? onIntervalChanged;

  final bool isRtl;

  /// How far the plan grid is currently scrolled, in pixels. Chips shift
  /// up by this much, so the lane's own height is just the visible
  /// viewport rather than a whole day.
  final double scrollOffset;

  /// Vertical scale of the plan grid. Null lets the lane derive it from
  /// its height (standalone use, where the lane *is* a whole day tall).
  final double? pixelsPerMinute;

  @override
  State<ReportLaneView> createState() => _ReportLaneViewState();
}

class _ReportLaneViewState extends State<ReportLaneView> {
  /// The dragged edge clamped to the visible grid. Delta math starts here so
  /// a chip whose real edge is past midnight (drawn at the grid bottom) still
  /// follows the pointer as soon as it moves inward.
  ReportBlock? _dragBase;
  ReportBlock? _dragPreview;
  bool _dragTop = true;
  double _dragDy = 0;
  double _dragPxPerMinute = 1;

  bool get _dragging => _dragBase != null && _dragPreview != null;

  DateTime get _gridStart => DateTime(
    widget.day.year,
    widget.day.month,
    widget.day.day,
  ).add(Duration(minutes: (widget.startHour * 60).round()));

  DateTime get _gridEnd => DateTime(
    widget.day.year,
    widget.day.month,
    widget.day.day,
  ).add(Duration(minutes: (widget.endHour * 60).round()));

  List<ReportBlock> get _displayBlocks {
    final preview = _dragPreview;
    if (preview == null) return widget.blocks;
    return [
      for (final block in widget.blocks)
        if (block.displayId == preview.displayId) preview else block,
    ];
  }

  void _beginHandleDrag(ReportBlock block, bool top, double pxPerMinute) {
    if (block.kind == ReportBlockKind.live) return;
    // Only the dragged edge is re-anchored; the other edge keeps its stored
    // time so fixing a clipped end never truncates a clipped start.
    final base = top
        ? (block.start.isBefore(_gridStart)
              ? resizedReportBlock(
                  block,
                  newStart: _gridStart,
                  snapMinutes: widget.snapMinutes,
                )
              : block)
        : (block.end.isAfter(_gridEnd)
              ? resizedReportBlock(
                  block,
                  newEnd: _gridEnd,
                  snapMinutes: widget.snapMinutes,
                )
              : block);
    setState(() {
      _dragBase = base;
      _dragPreview = base;
      _dragTop = top;
      _dragDy = 0;
      _dragPxPerMinute = pxPerMinute <= 0 ? 1 : pxPerMinute;
    });
  }

  void _updateHandleDrag(DragUpdateDetails details) {
    final base = _dragBase;
    if (base == null) return;
    _dragDy += details.delta.dy;
    final minutes = _dragDy / _dragPxPerMinute;
    var shifted = (_dragTop ? base.start : base.end).add(
      Duration(microseconds: (minutes * 60000000).round()),
    );
    // Never move an edge somewhere the lane cannot draw it: the chip stops
    // at the grid boundary and that boundary is what a release commits.
    if (_dragTop && shifted.isBefore(_gridStart)) shifted = _gridStart;
    if (!_dragTop && shifted.isAfter(_gridEnd)) shifted = _gridEnd;
    final preview = resizedReportBlock(
      base,
      newStart: _dragTop ? shifted : null,
      newEnd: _dragTop ? null : shifted,
      snapMinutes: widget.snapMinutes,
    );
    setState(() => _dragPreview = preview);
  }

  void _endDrag() {
    if (!_dragging) {
      _cancelDrag();
      return;
    }
    final base = _dragBase!;
    final preview = _dragPreview!;
    setState(() {
      _dragBase = null;
      _dragPreview = null;
    });
    // A drag that only pushes farther outside the grid changes nothing the
    // user can see, so it must not rewrite the report (that was how a
    // 1:30 AM report could be "updated" without the chip moving).
    if (preview.start == base.start && preview.end == base.end) {
      return;
    }
    widget.onIntervalChanged?.call(base, preview.start, preview.end);
  }

  void _cancelDrag() {
    if (_dragBase == null && _dragPreview == null) return;
    setState(() {
      _dragBase = null;
      _dragPreview = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The tinted background must not take pointers: only chips are
    // interactive, everything else belongs to the plan calendar below.
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.16),
                border: Border(
                  left: widget.isRtl
                      ? BorderSide.none
                      : BorderSide(
                          color: scheme.outlineVariant.withValues(alpha: 0.7),
                          width: 1,
                        ),
                  right: widget.isRtl
                      ? BorderSide(
                          color: scheme.outlineVariant.withValues(alpha: 0.7),
                          width: 1,
                        )
                      : BorderSide.none,
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final height = constraints.maxHeight;
              final minutes = ((widget.endHour - widget.startHour) * 60)
                  .clamp(1, 24 * 60)
                  .toDouble();
              if (!height.isFinite || height <= 0) {
                return const SizedBox.shrink();
              }
              final pxPerMinute = widget.pixelsPerMinute ?? height / minutes;
              final gridStart = DateTime(
                widget.day.year,
                widget.day.month,
                widget.day.day,
              ).add(Duration(minutes: (widget.startHour * 60).round()));
              // Chips that overlap in time fan out a little instead of hiding
              // each other completely (two reports over one stretch happen when
              // an event has more than one accepted entry).
              final laneEnds = <DateTime>[];
              final chips = <Widget>[];
              for (final block in _displayBlocks) {
                var lane = 0;
                while (lane < laneEnds.length &&
                    block.start.isBefore(laneEnds[lane])) {
                  lane++;
                }
                if (lane == laneEnds.length) {
                  laneEnds.add(block.end);
                } else {
                  laneEnds[lane] = block.end;
                }
                // Clamp to the grid's hour range: a block that starts before it
                // (or ends after) keeps the visible part at the right offset.
                final rawStart = block.start
                    .difference(gridStart)
                    .inMinutes
                    .toDouble();
                final rawEnd = block.end
                    .difference(gridStart)
                    .inMinutes
                    .toDouble();
                final top =
                    rawStart.clamp(0, minutes).toDouble() * pxPerMinute -
                    widget.scrollOffset;
                final bottom =
                    rawEnd.clamp(0, minutes).toDouble() * pxPerMinute -
                    widget.scrollOffset;
                final visible = bottom - top;
                final chipHeight = visible < 3 ? 3.0 : visible;
                // A very short report paints a thin bar, but its hit area stays
                // tall enough to tap and to hold two resize circles. The bar
                // stays centered on its real interval; only the grab area grows.
                final hitHeight = math.max(chipHeight, reportChipMinHitHeight);
                final hitTop = top - (hitHeight - chipHeight) / 2;
                // Fully scrolled out of the viewport: no chip at all, so an
                // off-screen report can never intercept a tap or paint over
                // the header.
                if (hitTop + hitHeight <= 0 || hitTop >= height) continue;
                chips.add(
                  Positioned(
                    top: hitTop,
                    left: lane * 8.0,
                    right: 0,
                    height: hitHeight,
                    child: ReportChip(
                      block: block,
                      color: widget.colorFor(block),
                      timeLabel: reportChipTimeLabel(block),
                      selected: block.displayId == widget.selectedId,
                      adjustable: block.kind != ReportBlockKind.live,
                      visualHeight: chipHeight,
                      onTap: () => widget.onTap(block),
                      onResizeStart: (top) =>
                          _beginHandleDrag(block, top, pxPerMinute),
                      onResizeUpdate: _updateHandleDrag,
                      onResizeEnd: _endDrag,
                      onResizeCancel: _cancelDrag,
                    ),
                  ),
                );
              }
              return SizedBox.expand(
                child: ClipRect(child: Stack(children: chips)),
              );
            },
          ),
        ),
      ],
    );
  }
}
