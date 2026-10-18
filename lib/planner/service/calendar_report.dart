import '../../nodes/model/node.dart';
import '../../reporting/model/reported_entry.dart';
import '../model/planner_event.dart';

enum ReportBlockKind { live, timer, accepted }

class ReportBlock {
  final String displayId;
  final String title;
  final DateTime start;
  final DateTime end;
  final ReportBlockKind kind;
  final String? eventId;
  final String? entryId;
  final ReportStatus? status;

  const ReportBlock({
    required this.displayId,
    required this.title,
    required this.start,
    required this.end,
    required this.kind,
    this.eventId,
    this.entryId,
    this.status,
  });
}

bool isReportDisplayId(String id) => id.startsWith('report:');

/// Finds an existing reported entry linked to [eventId], preferring a
/// manual (accepted) entry over an auto-generated one.
ReportedEntry? findReportEntryForEvent(
  Map<String, List<ReportedEntry>> reportsByDay,
  String eventId,
) {
  ReportedEntry? fallback;
  for (final entries in reportsByDay.values) {
    for (final entry in entries) {
      if (entry.eventId != eventId) continue;
      if (!entry.auto) return entry;
      fallback ??= entry;
    }
  }
  return fallback;
}

/// Builds a new manual report entry seeded from a task-event's planned
/// (or already timer-logged) time. The id reuses the auto-report scheme
/// (`rep:<eventId>`) so saving it via [ReportingCubit.upsertEntry] cleanly
/// overrides any auto entry for the same event.
ReportedEntry buildManualReportForEvent(PlannerEvent event) {
  final baseStart = event.actualStart ?? event.start;
  var start = baseStart;
  var end = event.actualEnd ?? event.end;
  if (event.allDay) {
    start = DateTime(baseStart.year, baseStart.month, baseStart.day, 9);
    end = start.add(const Duration(hours: 1));
  }
  if (!end.isAfter(start)) end = start.add(const Duration(hours: 1));
  return ReportedEntry(
    id: 'rep:${event.id}',
    eventId: event.id,
    placeId: event.placeId,
    title: event.subject,
    start: start,
    end: end,
    status: ReportStatus.attended,
    auto: false,
  );
}

List<ReportBlock> buildReportBlocks({
  required List<PlannerEvent> visibleEvents,
  required List<Node> nodes,
  required Map<String, List<ReportedEntry>> reportsByDay,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final accepted = <ReportedEntry>[];
  for (final entries in reportsByDay.values) {
    for (final entry in entries) {
      if (!entry.auto) accepted.add(entry);
    }
  }
  final acceptedByEvent = <String, List<ReportedEntry>>{};
  final extras = <ReportedEntry>[];
  for (final entry in accepted) {
    final eventId = entry.eventId;
    if (eventId == null) {
      extras.add(entry);
    } else {
      acceptedByEvent.putIfAbsent(eventId, () => []).add(entry);
    }
  }

  final nodesByEvent = <String, List<Node>>{};
  for (final node in nodes) {
    final calendarId = node.calendarEventId;
    if (calendarId != null) {
      nodesByEvent.putIfAbsent(calendarId, () => []).add(node);
    }
    final sourceId = node.sourceEventId;
    if (sourceId != null) {
      nodesByEvent.putIfAbsent(sourceId, () => []).add(node);
    }
  }
  final nodesById = {for (final node in nodes) node.id: node};

  final visibleEventIds = {for (final e in visibleEvents) e.id};
  final handledNodeIds = <String>{};

  final blocks = <ReportBlock>[];
  for (final event in visibleEvents) {
    if (event.allDay) continue;
    final linked = <Node>[];
    final seen = <String>{};
    for (final list in [
      nodesByEvent[event.id] ?? const <Node>[],
      if (event.taskId != null && nodesById[event.taskId] != null)
        [nodesById[event.taskId]!],
    ]) {
      for (final node in list) {
        if (seen.add(node.id)) {
          linked.add(node);
          handledNodeIds.add(node.id);
        }
      }
    }

    DateTime? liveStart = event.timerStartedAt;
    liveStart ??= _firstTrackingStart(linked);
    if (liveStart != null) {
      var end = at;
      if (!end.isAfter(liveStart)) {
        end = liveStart.add(const Duration(minutes: 1));
      }
      if (end.difference(liveStart) < const Duration(minutes: 1)) {
        end = liveStart.add(const Duration(minutes: 1));
      }
      blocks.add(ReportBlock(
        displayId: 'report:live:${event.id}',
        title: event.subject,
        start: liveStart,
        end: end,
        kind: ReportBlockKind.live,
        eventId: event.id,
      ));
      continue;
    }

    final reported = _reportedInterval(event, linked);
    if (reported != null) {
      blocks.add(ReportBlock(
        displayId: 'report:timer:${event.id}',
        title: event.subject,
        start: reported.start,
        end: reported.end,
        kind: ReportBlockKind.timer,
        eventId: event.id,
      ));
      continue;
    }

    final matches = acceptedByEvent[event.id];
    if (matches != null) {
      for (final entry in matches) {
        final end = entry.end.isAfter(entry.start)
            ? entry.end
            : entry.start.add(const Duration(hours: 1));
        blocks.add(ReportBlock(
          displayId: 'report:${entry.id}',
          title: entry.title,
          start: entry.start,
          end: end,
          kind: ReportBlockKind.accepted,
          eventId: event.id,
          entryId: entry.id,
          status: entry.status,
        ));
      }
    }
  }
  // Node-only pass: tasks recorded off the calendar (no linked visible
  // event) still produce report blocks, so tracking/reported time shows
  // up in the Plan + Report view instead of being dropped.
  for (final node in nodes) {
    if (handledNodeIds.contains(node.id)) continue;
    final linkedToVisible =
        (node.calendarEventId != null &&
            visibleEventIds.contains(node.calendarEventId)) ||
        (node.sourceEventId != null &&
            visibleEventIds.contains(node.sourceEventId));
    if (linkedToVisible) continue;

    final liveStart = node.timerStartedAt;
    if (liveStart != null) {
      var end = at;
      if (!end.isAfter(liveStart)) {
        end = liveStart.add(const Duration(minutes: 1));
      }
      if (end.difference(liveStart) < const Duration(minutes: 1)) {
        end = liveStart.add(const Duration(minutes: 1));
      }
      blocks.add(ReportBlock(
        displayId: 'report:live:${node.id}',
        title: node.title,
        start: liveStart,
        end: end,
        kind: ReportBlockKind.live,
        eventId: null,
      ));
      continue;
    }
    final actualStart = node.actualStart;
    final actualEnd = node.actualEnd;
    if (actualStart != null && actualEnd != null) {
      var end = actualEnd;
      if (!end.isAfter(actualStart)) {
        end = actualStart.add(const Duration(minutes: 1));
      }
      blocks.add(ReportBlock(
        displayId: 'report:timer:${node.id}',
        title: node.title,
        start: actualStart,
        end: end,
        kind: ReportBlockKind.timer,
        eventId: null,
      ));
    }
  }

  for (final entry in extras) {
    final end = entry.end.isAfter(entry.start)
        ? entry.end
        : entry.start.add(const Duration(hours: 1));
    blocks.add(ReportBlock(
      displayId: 'report:${entry.id}',
      title: entry.title,
      start: entry.start,
      end: end,
      kind: ReportBlockKind.accepted,
      entryId: entry.id,
      status: entry.status,
    ));
  }

  blocks.sort((a, b) => a.start.compareTo(b.start));
  return blocks;
}

DateTime? _firstTrackingStart(List<Node> linked) {
  for (final node in linked) {
    if (node.timerStartedAt != null) return node.timerStartedAt;
  }
  return null;
}

_DateRange? _reportedInterval(PlannerEvent event, List<Node> linked) {
  if (event.actualStart != null && event.actualEnd != null) {
    final start = event.actualStart!;
    var end = event.actualEnd!;
    if (!end.isAfter(start)) end = start.add(const Duration(minutes: 1));
    return _DateRange(start, end);
  }
  for (final node in linked) {
    if (node.actualStart != null && node.actualEnd != null) {
      final start = node.actualStart!;
      var end = node.actualEnd!;
      if (!end.isAfter(start)) end = start.add(const Duration(minutes: 1));
      return _DateRange(start, end);
    }
  }
  return null;
}

class _DateRange {
  final DateTime start;
  final DateTime end;

  const _DateRange(this.start, this.end);
}

PlannerEvent reportBlockToDisplayEvent(
  ReportBlock block, {
  PlannerEvent? template,
}) {
  final end = block.end.isAfter(block.start)
      ? block.end
      : block.start.add(const Duration(hours: 1));
  return PlannerEvent(
    id: block.displayId,
    subject: block.title,
    start: block.start,
    end: end,
    feedId: template?.feedId,
    classLabel: template?.classLabel,
    colorValue: template?.colorValue,
  );
}

/// Id prefix of the invisible full-day appointment that claims the first
/// lane of a day column in the Plan + Report view, so the report blocks get
/// a column of their own instead of every planned tile being cut in half.
const String reportLaneIdPrefix = 'reportlane:';

bool isReportLaneId(String id) => id.startsWith(reportLaneIdPrefix);

String reportLaneIdForDay(DateTime day) {
  final month = day.month.toString().padLeft(2, '0');
  final dayOfMonth = day.day.toString().padLeft(2, '0');
  return '$reportLaneIdPrefix${day.year}-$month-$dayOfMonth';
}

/// The day a report-lane id stands for, or null when [id] is not a lane id.
DateTime? reportLaneDayOf(String id) {
  if (!isReportLaneId(id)) return null;
  final parts = id.substring(reportLaneIdPrefix.length).split('-');
  if (parts.length != 3) return null;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return null;
  final parsed = DateTime(year, month, day);
  // DateTime normalizes overflow (2026-13-45 rolls into 2027); only accept
  // a canonical date so a stray id can never invent a day.
  if (parsed.year != year || parsed.month != month || parsed.day != day) {
    return null;
  }
  return parsed;
}

/// A full-day placeholder appointment. It never renders as an event: the
/// calendar page's appointment builder turns its tile into the report lane
/// (background + time-positioned report chips). Being an appointment is the
/// point — Syncfusion's layout engine then places every planned event of
/// that day beside it instead of on top of the reports.
PlannerEvent buildReportLaneEvent(DateTime day) => PlannerEvent(
      id: reportLaneIdForDay(day),
      subject: '',
      start: DateTime(day.year, day.month, day.day),
      end: DateTime(day.year, day.month, day.day, 23, 59, 59),
    );

/// Groups report blocks by the calendar day they start on, keyed by
/// midnight of that day. A block that crosses midnight stays with the day
/// it started on so it renders in one lane.
Map<DateTime, List<ReportBlock>> groupReportBlocksByDay(
  List<ReportBlock> blocks,
) {
  final grouped = <DateTime, List<ReportBlock>>{};
  for (final block in blocks) {
    final start = block.start;
    final day = DateTime(start.year, start.month, start.day);
    grouped.putIfAbsent(day, () => []).add(block);
  }
  return grouped;
}
