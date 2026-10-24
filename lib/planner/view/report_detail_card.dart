import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../reporting/bloc/places_cubit.dart';
import '../../reporting/bloc/reporting_cubit.dart';
import '../../reporting/model/reported_entry.dart';
import '../service/calendar_report.dart';

// Hoisted: the card rebuilds with the panel and DateFormat construction
// parses ICU skeletons.
final _reportTimeFormat = DateFormat('h:mm a');

/// Details of the report chip selected in the Plan + Report lane.
///
/// Tapping a report used to open only the event's generic detail, so the
/// reported interval the user actually tapped was invisible. This card
/// leads with that report — interval, length, status, place — and offers
/// [onRecord] to start a fresh recording for the same task.
class SelectedReportCard extends StatelessWidget {
  const SelectedReportCard({
    super.key,
    required this.report,
    this.eventSubject,
    this.onRecord,
  });

  final ReportBlock report;

  /// The event's subject. When the report title matches it, the card skips
  /// the title line so the panel doesn't repeat itself.
  final String? eventSubject;

  /// Starts recording another report for the same task. Null hides the
  /// button (live chips already record, and ownerless reports have no task).
  final VoidCallback? onRecord;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final live = report.kind == ReportBlockKind.live;
    final entry = _entryForReport(context);
    final placeName = _placeName(context, entry?.placeId);
    final status = report.status ?? entry?.status;
    final title = report.title.trim();
    final showTitle =
        title.isNotEmpty && (eventSubject == null || title != eventSubject);
    final statusBits = <String>[
      if (status != null) reportStatusLabel(status),
      if (placeName != null && placeName.isNotEmpty) placeName,
      if ((entry?.minutesAtPlace ?? 0) > 0)
        '${entry!.minutesAtPlace}m at place',
    ];
    final canRecord = onRecord != null && !live && report.recordable;
    return Container(
      key: ValueKey('selected-report:${report.displayId}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: Border.all(
          color: live
              ? const Color(0xFFFF5252)
              : theme.colorScheme.outlineVariant,
          width: live ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                switch (report.kind) {
                  ReportBlockKind.live => Icons.fiber_manual_record,
                  ReportBlockKind.timer => Icons.timer_outlined,
                  ReportBlockKind.accepted => Icons.fact_check_outlined,
                },
                size: 16,
                color: live
                    ? const Color(0xFFFF5252)
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  switch (report.kind) {
                    ReportBlockKind.live => 'Recording now',
                    ReportBlockKind.timer => 'Timer report',
                    ReportBlockKind.accepted => 'Report',
                  },
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (canRecord)
                FilledButton.tonalIcon(
                  key: ValueKey('report-record:${report.displayId}'),
                  onPressed: onRecord,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('Record again'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
            ],
          ),
          if (showTitle) ...[
            const SizedBox(height: 6),
            Text(
              title,
              style: theme.textTheme.titleSmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 4),
          Text(
            reportIntervalLabel(report, now: DateTime.now()),
            style: theme.textTheme.bodySmall,
          ),
          if (statusBits.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              statusBits.join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  ReportedEntry? _entryForReport(BuildContext context) {
    try {
      return findReportEntryByDisplayId(
        context.watch<ReportingCubit>().state,
        report.displayId,
      );
    } catch (_) {
      return null;
    }
  }

  String? _placeName(BuildContext context, String? placeId) {
    if (placeId == null) return null;
    try {
      return context.watch<PlacesCubit>().byId(placeId)?.name;
    } catch (_) {
      return null;
    }
  }
}

/// Time range and length for [report], e.g. `9:05 AM – 9:50 AM · 45m`, or a
/// running label for a live recording.
String reportIntervalLabel(ReportBlock report, {required DateTime now}) {
  if (report.kind == ReportBlockKind.live) {
    final elapsed = now.isAfter(report.start)
        ? now.difference(report.start)
        : Duration.zero;
    return 'Recording since ${_reportTimeFormat.format(report.start)} · '
        '${reportDurationLabel(elapsed)} so far';
  }
  final duration = report.end.isAfter(report.start)
      ? report.end.difference(report.start)
      : Duration.zero;
  return '${_reportTimeFormat.format(report.start)} – '
      '${_reportTimeFormat.format(report.end)} · '
      '${reportDurationLabel(duration)}';
}

/// Compact duration label: `45m`, `1h`, `1h 5m`.
String reportDurationLabel(Duration duration) {
  final minutes = duration.inMinutes < 0 ? 0 : duration.inMinutes;
  if (minutes < 60) return '${minutes}m';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '${hours}h' : '${hours}h ${rest}m';
}

/// Human label for a manual report's attendance status.
String reportStatusLabel(ReportStatus status) => switch (status) {
  ReportStatus.attended => 'Attended',
  ReportStatus.partial => 'Partially attended',
  ReportStatus.missed => 'Missed',
  ReportStatus.extra => 'Extra time',
};
