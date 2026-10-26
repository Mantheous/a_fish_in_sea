import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../common/undo/undo_cubit.dart';
import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/service/node_calendar.dart';
import '../../nodes/service/node_event_link.dart';
import '../../reporting/bloc/reporting_cubit.dart';
import '../../reporting/model/reported_entry.dart';
import '../bloc/calendar_cubit.dart';
import '../bloc/calendar_draft_cubit.dart';
import '../model/planner_event.dart';
import '../service/calendar_report.dart';
import 'calendar_snackbars.dart';

// Hoisted: the copy snackbar formats two times per tap; DateFormat
// construction parses ICU skeletons.
final _copyTimeFormat = DateFormat('h:mm a');

/// Whether a plan tile can offer a one-tap copy to the report lane.
///
/// True for ordinary timed events with no report yet: not all-day (the
/// lane skips those, so a copy would paint nothing), not a draft, report,
/// or node block, not currently recording, with no timer sessions, and
/// with no report block already covering it ([reportedEventIds] comes
/// from the calendar projection's live blocks).
bool isCopyablePlanEvent(
  PlannerEvent event, {
  required Set<String> reportedEventIds,
}) {
  if (event.allDay) return false;
  if (event.id == calendarDraftEventId) return false;
  if (isReportDisplayId(event.id)) return false;
  if (isNodeBlockId(event.id)) return false;
  if (reportedEventIds.contains(event.id)) return false;
  if (event.isTracking) return false;
  if (event.hasReported) return false;
  return true;
}

/// Pure entry builder behind [copyPlanEventToReport]: returns the accepted
/// entry to write, or null when the plan is ineligible or already reported.
/// Unit-tested without a widget tree; the context wrapper below only adds
/// the upsert and the undo snackbar.
ReportedEntry? buildPlanCopyEntry(
  PlannerEvent event, {
  required Set<String> reportedEventIds,
  required Map<String, List<ReportedEntry>> reportsByDay,
}) {
  if (!isCopyablePlanEvent(event, reportedEventIds: reportedEventIds)) {
    return null;
  }
  if (findReportEntryForEvent(reportsByDay, event.id) != null) return null;
  return buildManualReportForEvent(event);
}

/// Whether [reportsByDay] already holds a manual entry for [eventId].
/// The event detail sections use this (they have no projection handy)
/// to hide the copy button once the plan is already reported.
bool planEventHasManualReport(
  Map<String, List<ReportedEntry>> reportsByDay,
  String eventId,
) =>
    findReportEntryForEvent(reportsByDay, eventId) != null;

/// Copies a plan event's planned time into the report store as an
/// accepted entry, for when the day went as scheduled but nothing was
/// recorded. Returns true when an entry was written.
///
/// Guards mirror [isCopyablePlanEvent] plus a live check against the
/// reporting store, so double-taps and stale projections never duplicate.
/// Shows the calendar undo snackbar on success (the reporting cubit is
/// revertable, so Undo reverts the copy).
bool copyPlanEventToReport(
  BuildContext context,
  PlannerEvent event, {
  Set<String>? reportedEventIds,
}) {
  if (event.allDay) return false;
  if (event.id == calendarDraftEventId) return false;
  if (isReportDisplayId(event.id)) return false;
  if (isNodeBlockId(event.id)) return false;
  if (event.isTracking || event.hasReported) return false;
  if (reportedEventIds?.contains(event.id) ?? false) return false;
  // A task's recorded time covers every one of its plan events. Copying
  // one event's plan while the task already has a recording would count
  // the same work twice, so refuse to copy a sibling's time.
  try {
    final backing = NodeEventLink.backingNodeFor(
      context.read<NodeCubit>(),
      context.read<CalendarCubit>(),
      event.id,
    );
    if (backing != null && (backing.hasReported || backing.isTracking)) {
      return false;
    }
  } catch (_) {}
  ReportingCubit reporting;
  try {
    reporting = context.read<ReportingCubit>();
  } catch (_) {
    return false;
  }
  final entry = buildPlanCopyEntry(
    event,
    reportedEventIds: reportedEventIds ?? const {},
    reportsByDay: reporting.state,
  );
  if (entry == null) return false;
  final day = DateTime(entry.start.year, entry.start.month, entry.start.day);
  reporting.upsertEntry(day, entry);
  try {
    final messenger = ScaffoldMessenger.of(context);
    final undo = context.read<UndoCubit>();
    showCalendarUndoSnackBar(
      messenger: messenger,
      message:
          'Copied to report · ${_copyTimeFormat.format(entry.start)} – '
          '${_copyTimeFormat.format(entry.end)}',
      onUndo: undo.undo,
    );
  } catch (_) {}
  return true;
}

/// Small copy badge for a plan tile in the Plan + Report view.
///
/// Chromeless like the tile's play badge (plain icon, no bubble) so it
/// reads as tile chrome instead of a sticker. The caller suppresses the
/// calendar tap on [onTapDown] (same trick as the play badge and resize
/// handles) and copies on [onTap].
class PlanCopyBadge extends StatelessWidget {
  const PlanCopyBadge({
    super.key,
    required this.onTapDown,
    required this.onTap,
  });

  final VoidCallback onTapDown;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => onTapDown(),
      onTap: onTap,
      child: Tooltip(
        message: 'Copy plan to report',
        child: Semantics(
          button: true,
          label: 'Copy plan to report',
          child: const Padding(
            padding: EdgeInsets.all(5),
            child: Icon(
              Icons.content_copy,
              size: 18,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
