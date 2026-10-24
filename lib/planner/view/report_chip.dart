import 'package:flutter/material.dart';

import '../service/calendar_report.dart';

const _liveColor = Color(0xFFFF5252);

/// Smallest vertical hit area a report chip gets. A short report (a few
/// seconds, a zero-minute entry) otherwise paints a 1–3px bar that is
/// impossible to tap, and the resize circles never appear because the chip
/// measures shorter than their 12px floor.
const double reportChipMinHitHeight = 20;

/// One report block inside the Plan + Report lane.
///
/// [visualHeight] is the painted bar height (the reported duration); the
/// widget's own layout height can be taller so the chip stays tappable and
/// its resize circles have room even when the report is only a few minutes.
class ReportChip extends StatelessWidget {
  const ReportChip({
    super.key,
    required this.block,
    required this.color,
    required this.timeLabel,
    required this.selected,
    required this.adjustable,
    required this.visualHeight,
    required this.onTap,
    this.onResizeStart,
    this.onResizeUpdate,
    this.onResizeEnd,
    this.onResizeCancel,
  });

  final ReportBlock block;
  final Color color;
  final String timeLabel;
  final bool selected;
  final bool adjustable;
  final double visualHeight;
  final VoidCallback onTap;
  final ValueChanged<bool>? onResizeStart;
  final GestureDragUpdateCallback? onResizeUpdate;
  final VoidCallback? onResizeEnd;
  final VoidCallback? onResizeCancel;

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
        child: Tooltip(
          message:
              '$title\n'
              '$timeLabel'
              '${selected && adjustable ? '\nDrag the white circles to adjust the time' : ''}',
          waitDuration: const Duration(milliseconds: 500),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final hitHeight = constraints.maxHeight;
              final width = constraints.maxWidth;
              final visual = visualHeight.isFinite ? visualHeight : hitHeight;
              // Week view gives each report track half of a day cell. Keep
              // the title visible in that narrow column; only collapse to
              // a color bar when it can't fit even a short label.
              final compact = width.isFinite && width < 44;
              // Text decisions follow the painted bar, not the expanded hit
              // area: a zero-minute report gets circles, but no room for text.
              final showText = !compact && (visual.isInfinite || visual >= 20);
              final showTime =
                  !compact &&
                  (width.isInfinite || width >= 100) &&
                  (visual.isInfinite || visual >= 34);
              // The same threshold as event tiles: below ~12px there is no
              // room for two grabbable circles. Short report chips now carry
              // a taller hit area, so they pass this check too.
              final showHandles =
                  selected &&
                  adjustable &&
                  hitHeight.isFinite &&
                  hitHeight >= 12 &&
                  width.isFinite &&
                  width >= 24;
              final compactHandles =
                  compact || (hitHeight.isFinite && hitHeight < 58);
              final tightHandles =
                  compactHandles && hitHeight.isFinite && hitHeight < 40;
              // Center the painted bar inside a taller hit area so the bar
              // still starts exactly at the reported time.
              final visualTop = hitHeight.isFinite && visual.isFinite
                  ? ((hitHeight - visual) / 2).clamp(0.0, hitHeight)
                  : 0.0;
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
                // chip's hit area.
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned(
                    top: visualTop,
                    left: 0,
                    right: 0,
                    height: visual.isFinite ? visual : null,
                    child: Container(
                      key: ValueKey('report-chip:${block.displayId}'),
                      margin: EdgeInsets.symmetric(
                        vertical: visual >= 6 ? 1 : 0,
                      ),
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
                      child: content == null
                          ? const SizedBox.shrink()
                          : ClipRect(child: content),
                    ),
                  ),
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
                ],
              );
            },
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
