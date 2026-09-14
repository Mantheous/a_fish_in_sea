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
        if (seen.add(node.id)) linked.add(node);
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
