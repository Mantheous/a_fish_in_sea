import '../../common/time/time_session.dart';
import '../../nodes/model/node.dart';
import '../../reporting/model/reported_entry.dart';
import '../model/event_reschedule.dart';
import '../model/planner_event.dart';

enum ReportBlockKind { live, timer, accepted }

const String reportDisplayIdPrefix = 'report:';
const String reportLiveDisplayIdPrefix = '${reportDisplayIdPrefix}live:';
const String reportTimerDisplayIdPrefix = '${reportDisplayIdPrefix}timer:';

/// Separates the owner id from the recorded session id inside a timer
/// report display id. `#` never appears in ids the app generates.
const String reportSessionSeparator = '#';

/// Display id for a timer block owned by an event or a calendar-less node.
/// [sessionId] keeps sibling recordings of one task distinct.
String reportTimerDisplayIdFor(String ownerId, {String? sessionId}) =>
    sessionId == null || sessionId.isEmpty
    ? '$reportTimerDisplayIdPrefix$ownerId'
    : '$reportTimerDisplayIdPrefix$ownerId$reportSessionSeparator$sessionId';

/// Owner id encoded in a timer/live display id (`report:timer:<id>` or
/// `report:live:<id>`), which is an event id for event-backed blocks and a
/// node id for node-only blocks. Null for manual entry ids and non-reports.
String? reportOwnerIdForDisplayId(String displayId) {
  final String raw;
  if (displayId.startsWith(reportTimerDisplayIdPrefix)) {
    raw = displayId.substring(reportTimerDisplayIdPrefix.length);
  } else if (displayId.startsWith(reportLiveDisplayIdPrefix)) {
    raw = displayId.substring(reportLiveDisplayIdPrefix.length);
  } else {
    return null;
  }
  final cut = raw.indexOf(reportSessionSeparator);
  final owner = cut < 0 ? raw : raw.substring(0, cut);
  return owner.isEmpty ? null : owner;
}

class ReportBlock {
  final String displayId;
  final String title;
  final DateTime start;
  final DateTime end;
  final ReportBlockKind kind;
  final String? eventId;
  final String? entryId;
  final ReportStatus? status;

  /// The recorded run this block shows, when it is one of several. Null
  /// for accepted entries, live blocks, and legacy single intervals.
  final String? sessionId;

  /// True when the block resolves to an event or task node, so the lane can
  /// offer a play button that records another report for it. Ownerless
  /// manual entries (reports typed in without a linked task) stay false.
  final bool recordable;

  const ReportBlock({
    required this.displayId,
    required this.title,
    required this.start,
    required this.end,
    required this.kind,
    this.eventId,
    this.entryId,
    this.status,
    this.sessionId,
    this.recordable = false,
  });

  ReportBlock copyWith({String? title, DateTime? start, DateTime? end}) =>
      ReportBlock(
        displayId: displayId,
        title: title ?? this.title,
        start: start ?? this.start,
        end: end ?? this.end,
        kind: kind,
        eventId: eventId,
        entryId: entryId,
        status: status,
        sessionId: sessionId,
        recordable: recordable,
      );
}

/// Applies a drag on a report chip's start or end edge. Snaps to
/// [snapMinutes] and never collapses the interval below one minute, matching
/// the calendar's event resize handles.
ReportBlock resizedReportBlock(
  ReportBlock block, {
  DateTime? newStart,
  DateTime? newEnd,
  int snapMinutes = 1,
}) {
  final start = newStart == null
      ? block.start
      : snapToInterval(newStart, snapMinutes);
  var end = newEnd == null ? block.end : snapToInterval(newEnd, snapMinutes);
  if (!end.isAfter(start)) end = start.add(const Duration(minutes: 1));
  return block.copyWith(start: start, end: end);
}

bool isReportDisplayId(String id) => id.startsWith(reportDisplayIdPrefix);

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

/// Finds the manual entry a report display id points at
/// (`report:<entryId>`). Timer and live ids carry their event id instead,
/// so those lookups come back null here.
ReportedEntry? findReportEntryByDisplayId(
  Map<String, List<ReportedEntry>> reportsByDay,
  String displayId,
) {
  for (final entries in reportsByDay.values) {
    for (final entry in entries) {
      if ('$reportDisplayIdPrefix${entry.id}' == displayId) return entry;
    }
  }
  return null;
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
  // One task can own several plan events (taskId links plus direct
  // calendarEventId/sourceEventId links). The node's timer and sessions are
  // mirrored onto every linked event for cache alignment, so without a
  // global guard the same recording renders once per event. Session ids are
  // stable across mirrors (TimeSession.idFor), so they dedupe the copies
  // while genuinely distinct runs stay separate. Live blocks dedupe by the
  // owning node for the same reason.
  final emittedSessionIds = <String>{};
  final emittedLiveNodeIds = <String>{};

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
    String? liveNodeId;
    if (liveStart == null) {
      for (final node in linked) {
        if (node.timerStartedAt != null) {
          liveStart = node.timerStartedAt;
          liveNodeId = node.id;
          break;
        }
      }
    }
    var emitLive = false;
    if (liveStart != null) {
      if (liveNodeId != null) {
        // Node-owned timer mirrored onto every linked event: show once.
        emitLive = emittedLiveNodeIds.add(liveNodeId);
      } else {
        emitLive = true;
      }
    }
    if (emitLive) {
      var end = at;
      if (!end.isAfter(liveStart!)) {
        end = liveStart.add(const Duration(minutes: 1));
      }
      if (end.difference(liveStart) < const Duration(minutes: 1)) {
        end = liveStart.add(const Duration(minutes: 1));
      }
      blocks.add(
        ReportBlock(
          displayId: '$reportLiveDisplayIdPrefix${event.id}',
          title: event.subject,
          start: liveStart,
          end: end,
          kind: ReportBlockKind.live,
          eventId: event.id,
          recordable: true,
        ),
      );
    }

    final sessions = _recordedSessions(event, linked);
    if (sessions.isNotEmpty) {
      final hasMultiple = sessions.length > 1;
      for (final session in sessions) {
        if (!emittedSessionIds.add(session.id)) continue;
        blocks.add(
          ReportBlock(
            displayId: hasMultiple
                ? reportTimerDisplayIdFor(event.id, sessionId: session.id)
                : '$reportTimerDisplayIdPrefix${event.id}',
            title: event.subject,
            start: session.start,
            end: session.end,
            kind: ReportBlockKind.timer,
            eventId: event.id,
            sessionId: session.id,
            recordable: true,
          ),
        );
      }
      continue;
    }
    if (liveStart != null) continue;

    final matches = acceptedByEvent[event.id];
    if (matches != null) {
      for (final entry in matches) {
        final end = entry.end.isAfter(entry.start)
            ? entry.end
            : entry.start.add(const Duration(hours: 1));
        blocks.add(
          ReportBlock(
            displayId: '$reportDisplayIdPrefix${entry.id}',
            title: entry.title,
            start: entry.start,
            end: end,
            kind: ReportBlockKind.accepted,
            eventId: event.id,
            entryId: entry.id,
            status: entry.status,
            recordable: true,
          ),
        );
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
      blocks.add(
        ReportBlock(
          displayId: '$reportLiveDisplayIdPrefix${node.id}',
          title: node.title,
          start: liveStart,
          end: end,
          kind: ReportBlockKind.live,
          eventId: null,
          recordable: true,
        ),
      );
    }
    for (final session in node.recordedSessions) {
      final many = node.sessions.length > 1;
      blocks.add(
        ReportBlock(
          displayId: many
              ? reportTimerDisplayIdFor(node.id, sessionId: session.id)
              : '$reportTimerDisplayIdPrefix${node.id}',
          title: node.title,
          start: session.start,
          end: session.end,
          kind: ReportBlockKind.timer,
          eventId: null,
          sessionId: session.id,
          recordable: true,
        ),
      );
    }
  }

  for (final entry in extras) {
    final end = entry.end.isAfter(entry.start)
        ? entry.end
        : entry.start.add(const Duration(hours: 1));
    blocks.add(
      ReportBlock(
        displayId: '$reportDisplayIdPrefix${entry.id}',
        title: entry.title,
        start: entry.start,
        end: end,
        kind: ReportBlockKind.accepted,
        entryId: entry.id,
        status: entry.status,
      ),
    );
  }

  blocks.sort((a, b) => a.start.compareTo(b.start));
  return blocks;
}

/// Every distinct recorded run on an event and the tasks linked to it.
///
/// Task-event pairs mirror the same sessions, so ids dedupe the copies.
/// When any side carries an explicit session list, legacy aggregate
/// intervals are ignored: those spans would otherwise show up as an extra
/// block after the first multi-session stop.
List<TimeSession> _recordedSessions(PlannerEvent event, List<Node> linked) {
  final explicit = <String, TimeSession>{};
  for (final session in event.sessions) {
    explicit[session.id] = session;
  }
  for (final node in linked) {
    for (final session in node.sessions) {
      explicit[session.id] = session;
    }
  }
  if (explicit.isNotEmpty) return _sortedSessions(explicit.values);

  final legacy = <String, TimeSession>{};
  for (final session in event.recordedSessions) {
    legacy[session.id] = session;
  }
  for (final node in linked) {
    for (final session in node.recordedSessions) {
      legacy[session.id] = session;
    }
  }
  return _sortedSessions(legacy.values);
}

List<TimeSession> _sortedSessions(Iterable<TimeSession> sessions) =>
    sessions.toList()..sort((a, b) => a.start.compareTo(b.start));

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
