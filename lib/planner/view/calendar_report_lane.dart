import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../service/calendar_report.dart';

// Hoisted: DateFormat construction parses ICU skeletons; the lane can hold
// a dozen chips and this runs on every calendar rebuild.
final _chipTimeFormat = DateFormat('h:mm a');

const _liveColor = Color(0xFFFF5252);

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
typedef ReportIntervalChanged = void Function(
  ReportBlock block,
  DateTime start,
  DateTime end,
);

/// The report column of one day in the Plan + Report view.
///
/// Syncfusion lays this widget out as the tile of the day's invisible
/// lane appointment in the report calendar. It paints the trailing half of
/// that day, directly beside the plan calendar's leading half.
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
    this.onDeleted,
    this.isRtl = false,
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

  /// Deletes a selected recording. Live recordings never call this.
  final ValueChanged<ReportBlock>? onDeleted;

  final bool isRtl;

  @override
  State<ReportLaneView> createState() => _ReportLaneViewState();
}

class _ReportLaneViewState extends State<ReportLaneView> {
  ReportBlock? _dragOriginal;
  ReportBlock? _dragPreview;
  bool _dragTop = true;
  double _dragDy = 0;
  double _dragPxPerMinute = 1;

  bool get _dragging => _dragOriginal != null && _dragPreview != null;

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
    setState(() {
      _dragOriginal = block;
      _dragPreview = block;
      _dragTop = top;
      _dragDy = 0;
      _dragPxPerMinute = pxPerMinute <= 0 ? 1 : pxPerMinute;
    });
  }

  void _updateHandleDrag(DragUpdateDetails details) {
    final original = _dragOriginal;
    if (original == null) return;
    _dragDy += details.delta.dy;
    final minutes = _dragDy / _dragPxPerMinute;
    final shifted = (_dragTop ? original.start : original.end).add(
      Duration(microseconds: (minutes * 60000000).round()),
    );
    final preview = resizedReportBlock(
      original,
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
    final original = _dragOriginal!;
    final preview = _dragPreview!;
    setState(() {
      _dragOriginal = null;
      _dragPreview = null;
    });
    if (preview.start == original.start && preview.end == original.end) {
      return;
    }
    widget.onIntervalChanged?.call(original, preview.start, preview.end);
  }

  void _cancelDrag() {
    if (_dragOriginal == null && _dragPreview == null) return;
    setState(() {
      _dragOriginal = null;
      _dragPreview = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          final minutes = ((widget.endHour - widget.startHour) * 60)
              .clamp(1, 24 * 60)
              .toDouble();
          if (!height.isFinite || height <= 0) {
            return const SizedBox.shrink();
          }
          final pxPerMinute = height / minutes;
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
            final rawEnd = block.end.difference(gridStart).inMinutes.toDouble();
            final top = rawStart.clamp(0, minutes).toDouble() * pxPerMinute;
            final bottom = rawEnd.clamp(0, minutes).toDouble() * pxPerMinute;
            final visible = bottom - top;
            final chipHeight = visible < 3 ? 3.0 : visible;
            chips.add(
              Positioned(
                top: top,
                left: lane * 8.0,
                right: 0,
                height: chipHeight,
                child: _ReportChip(
                  block: block,
                  color: widget.colorFor(block),
                  timeLabel: reportChipTimeLabel(block),
                  selected: block.displayId == widget.selectedId,
                  adjustable: block.kind != ReportBlockKind.live,
                  onTap: () => widget.onTap(block),
                  onResizeStart: (top) =>
                      _beginHandleDrag(block, top, pxPerMinute),
                  onResizeUpdate: _updateHandleDrag,
                  onResizeEnd: _endDrag,
                  onResizeCancel: _cancelDrag,
                  onDelete: block.kind == ReportBlockKind.live
                      ? null
                      : () => widget.onDeleted?.call(block),
                ),
              ),
            );
          }
          return SizedBox.expand(
            child: ClipRect(child: Stack(children: chips)),
          );
        },
      ),
    );
  }
}

class _ReportChip extends StatelessWidget {
  const _ReportChip({
    required this.block,
    required this.color,
    required this.timeLabel,
    required this.selected,
    required this.adjustable,
    required this.onTap,
    this.onResizeStart,
    this.onResizeUpdate,
    this.onResizeEnd,
    this.onResizeCancel,
    this.onDelete,
  });

  final ReportBlock block;
  final Color color;
  final String timeLabel;
  final bool selected;
  final bool adjustable;
  final VoidCallback onTap;
  final ValueChanged<bool>? onResizeStart;
  final GestureDragUpdateCallback? onResizeUpdate;
  final VoidCallback? onResizeEnd;
  final VoidCallback? onResizeCancel;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final live = block.kind == ReportBlockKind.live;
    final title = block.title.isEmpty ? 'Report' : block.title;
    return Semantics(
      button: true,
      selected: selected,
      label: '$title · $timeLabel',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: selected ? onDelete : null,
        child: Tooltip(
          message:
              '$title\n'
              '$timeLabel'
              '${selected && adjustable ? '\nDrag the white circles to adjust the time' : ''}'
              '${selected && onDelete != null ? '\nTap × or long-press to delete this recording' : ''}',
          waitDuration: const Duration(milliseconds: 500),
          child: Container(
            key: ValueKey('report-chip:${block.displayId}'),
            margin: const EdgeInsets.symmetric(vertical: 1),
            decoration: BoxDecoration(
              color: live ? color : color.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(6),
              border: live
                  ? Border.all(color: _liveColor, width: 2)
                  : selected
                  ? Border.all(color: Colors.white, width: 2)
                  : null,
              boxShadow: selected
                  ? const [
                      BoxShadow(
                        color: Colors.black38,
                        blurRadius: 4,
                        offset: Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final height = constraints.maxHeight;
                final width = constraints.maxWidth;
                // Week view gives each report track half of a day cell. Keep
                // the title visible in that narrow column; only collapse to
                // a color bar when it can't fit even a short label.
                final compact = width.isFinite && width < 44;
                final showText =
                    !compact && (height.isInfinite || height >= 20);
                final showTime =
                    !compact &&
                    (width.isInfinite || width >= 100) &&
                    (height.isInfinite || height >= 34);
                // The same threshold as event tiles: below ~12px there is no
                // room for two grabbable circles.
                final showHandles =
                    selected &&
                    adjustable &&
                    height.isFinite &&
                    height >= 12 &&
                    width.isFinite &&
                    width >= 24;
                final compactHandles =
                    compact || (height.isFinite && height < 58);
                final tightHandles =
                    compactHandles && height.isFinite && height < 40;
                Widget? content;
                if (showText) {
                  content = Padding(
                    padding: const EdgeInsets.fromLTRB(6, 3, 6, 3),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (live)
                              const Padding(
                                padding: EdgeInsets.only(right: 3),
                                child: Icon(
                                  Icons.fiber_manual_record,
                                  size: 12,
                                  color: _liveColor,
                                ),
                              ),
                            if (block.kind == ReportBlockKind.timer)
                              const Padding(
                                padding: EdgeInsets.only(right: 3),
                                child: Icon(
                                  Icons.timer_outlined,
                                  size: 12,
                                  color: Colors.white,
                                ),
                              ),
                            if (block.kind == ReportBlockKind.accepted)
                              const Padding(
                                padding: EdgeInsets.only(right: 3),
                                child: Icon(
                                  Icons.fact_check,
                                  size: 12,
                                  color: Colors.white,
                                ),
                              ),
                            Flexible(
                              child: Text(
                                block.title.isEmpty ? 'Report' : block.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (showTime) ...[
                          const SizedBox(height: 2),
                          Text(
                            timeLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                }
                return Stack(
                  // Nothing (the circles included) may paint outside the
                  // chip's rounded body.
                  clipBehavior: Clip.hardEdge,
                  children: [
                    if (content != null) content,
                    if (showHandles)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: SizedBox(
                            width: compactHandles ? 40 : 48,
                            child: _resizeHandle(
                              top: true,
                              compact: compactHandles,
                              tight: tightHandles,
                            ),
                          ),
                        ),
                      ),
                    if (showHandles)
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: SizedBox(
                            width: compactHandles ? 40 : 48,
                            child: _resizeHandle(
                              top: false,
                              compact: compactHandles,
                              tight: tightHandles,
                            ),
                          ),
                        ),
                      ),
                    if (selected &&
                        onDelete != null &&
                        (height.isInfinite || height >= 12) &&
                        (width.isInfinite || width >= 28))
                      Positioned(top: 1, right: 1, child: _deleteBadge()),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Small × on a selected chip. The chip sits on a dense time grid, so the
  /// badge is kept to 16px and overlaid on the top-right corner.
  Widget _deleteBadge() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onDelete,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Semantics(
          button: true,
          label: 'Delete recorded time',
          child: Container(
            key: ValueKey('report-delete:${block.displayId}'),
            width: 16,
            height: 16,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 1.5),
              boxShadow: const [
                BoxShadow(color: Colors.black38, blurRadius: 2),
              ],
            ),
            child: Icon(Icons.close, size: 11, color: color),
          ),
        ),
      ),
    );
  }

  /// White grab circle centered on the chip's start or end edge, drawn the
  /// same way as the calendar's event resize handles.
  Widget _resizeHandle({
    required bool top,
    required bool compact,
    required bool tight,
  }) {
    final grabHeight = compact ? 20.0 : 28.0;
    final diameter = compact ? 14.0 : 18.0;
    final alignment = top
        ? (tight ? Alignment.topLeft : Alignment.topCenter)
        : (tight ? Alignment.bottomRight : Alignment.bottomCenter);
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onVerticalDragStart: (_) => onResizeStart?.call(top),
      onVerticalDragUpdate: onResizeUpdate,
      onVerticalDragEnd: (_) => onResizeEnd?.call(),
      onVerticalDragCancel: onResizeCancel,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpDown,
        child: Container(
          height: grabHeight,
          alignment: alignment,
          padding: EdgeInsets.only(
            top: 2,
            bottom: 2,
            left: tight ? 4 : 0,
            right: tight ? 4 : 0,
          ),
          child: Semantics(
            label: top
                ? 'Drag to adjust report start'
                : 'Drag to adjust report end',
            child: Container(
              width: diameter,
              height: diameter,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                  color: color.withValues(alpha: 0.9),
                  width: compact ? 2.5 : 3,
                ),
                boxShadow: const [
                  BoxShadow(color: Colors.black38, blurRadius: 3),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
