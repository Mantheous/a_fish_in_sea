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

/// The report column of one day in the Plan + Report view.
///
/// Syncfusion lays this widget out as the tile of the day's invisible
/// lane appointment: a full-height column at the day's left edge. Report
/// blocks are painted inside it at their own time position, so the column
/// reads as a second, dedicated timeline next to the planned events
/// instead of every planned tile being cut in half.
class ReportLaneView extends StatelessWidget {
  const ReportLaneView({
    super.key,
    required this.blocks,
    required this.day,
    required this.startHour,
    required this.endHour,
    required this.colorFor,
    required this.onTap,
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.16),
        border: Border(
          right: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.55),
          ),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          final minutes = ((endHour - startHour) * 60)
              .clamp(1, 24 * 60)
              .toDouble();
          if (!height.isFinite || height <= 0 || blocks.isEmpty) {
            return const SizedBox.shrink();
          }
          final pxPerMinute = height / minutes;
          final gridStart = DateTime(
            day.year,
            day.month,
            day.day,
          ).add(Duration(minutes: (startHour * 60).round()));
          // Chips that overlap in time fan out a little instead of hiding
          // each other completely (two reports over one stretch happen when
          // an event has more than one accepted entry).
          final laneEnds = <DateTime>[];
          final chips = <Widget>[];
          for (final block in blocks) {
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
                  color: colorFor(block),
                  timeLabel: reportChipTimeLabel(block),
                  onTap: () => onTap(block),
                ),
              ),
            );
          }
          return ClipRect(child: Stack(children: chips));
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
    required this.onTap,
  });

  final ReportBlock block;
  final Color color;
  final String timeLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final live = block.kind == ReportBlockKind.live;
    return Semantics(
      button: true,
      label: '${block.title.isEmpty ? 'Report' : block.title} · $timeLabel',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Tooltip(
          message:
              '${block.title.isEmpty ? 'Report' : block.title}\n'
              '$timeLabel',
          waitDuration: const Duration(milliseconds: 500),
          child: Container(
            key: ValueKey('report-chip:${block.displayId}'),
            margin: const EdgeInsets.symmetric(vertical: 1),
            decoration: BoxDecoration(
              color: live ? color : color.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(6),
              border: live ? Border.all(color: _liveColor, width: 2) : null,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final height = constraints.maxHeight;
                final width = constraints.maxWidth;
                // The report column can be a narrow strip (week view, or a
                // small window): below roughly one icon plus a couple of
                // letters the chip is just its colour bar, described by the
                // tooltip/semantics for anyone who needs the words.
                final compact = width.isFinite && width < 64;
                final showText =
                    !compact && (height.isInfinite || height >= 20);
                final showTime =
                    !compact &&
                    (width.isInfinite || width >= 100) &&
                    (height.isInfinite || height >= 34);
                if (!showText) return const SizedBox.shrink();
                return Padding(
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
              },
            ),
          ),
        ),
      ),
    );
  }
}
