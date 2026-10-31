import '../../common/time/time_session.dart';
import '../../nodes/model/node.dart';
import '../../reporting/model/reported_entry.dart';
import '../model/event_reschedule.dart';
import '../model/planner_event.dart';

part 'calendar_report_sessions.dart';
part 'calendar_report_identity.dart';

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
  final accepted = <(String, ReportedEntry)>[];
  for (final day in reportsByDay.entries) {
    for (final entry in day.value) {
      if (!entry.auto) accepted.add((day.key, entry));
    }
  }
  final acceptedByEvent = <String, List<(String, ReportedEntry)>>{};
  final extras = <(String, ReportedEntry)>[];
  for (final (day, entry) in accepted) {
    final eventId = entry.eventId;
    if (eventId == null) {
      extras.add((day, entry));
    } else {
      acceptedByEvent.putIfAbsent(eventId, () => []).add((day, entry));
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

  // All-day rows never enter the timed pass, so they must not count as
  // "handled" here either. A task can carry recorded sessions (started
  // while the block was timed, or on the task itself) and still be linked
  // to an all-day event; skipping the node pass dropped that time from the
  // lane and from anything built on these blocks.
  final visibleEventIds = {
    for (final e in visibleEvents)
      if (!e.allDay) e.id,
  };
  final handledNodeIds = <String>{};
  // One task can own several plan events (taskId links plus direct
  // calendarEventId/sourceEventId links). Its timer and sessions are
  // mirrored onto every linked event for cache alignment, so each run must
  // be attributed to the event it actually happened during — Toggl-style,
  // every entry sits on its own row — and rendered exactly once. Session
  // ids are stable across mirrors (TimeSession.idFor), but unrelated tasks
  // can have identical ids, so ownership and deduplication also need the task.
  final eventById = {for (final e in visibleEvents) e.id: e};
  final eventsByNode = <String, List<PlannerEvent>>{};
  void linkEvent(String? nodeId, PlannerEvent event) {
    if (nodeId == null || event.allDay) return;
    final list = eventsByNode[nodeId] ??= <PlannerEvent>[];
    if (!list.any((e) => e.id == event.id)) list.add(event);
  }

  for (final event in visibleEvents) {
    linkEvent(event.taskId, event);
  }
  for (final node in nodes) {
    for (final eventId in [node.calendarEventId, node.sourceEventId]) {
      final event = eventId == null ? null : eventById[eventId];
      if (event != null) linkEvent(node.id, event);
    }
  }
  String? taskOwner(PlannerEvent event) =>
      event.taskId ?? nodesByEvent[event.id]?.first.id;
  (bool, String, String) sessionKey(PlannerEvent event, String sessionId) {
    final nodeId = taskOwner(event);
    // Node and event ids also have separate namespaces.
    return (nodeId != null, nodeId ?? event.id, sessionId);
  }

  final sessionOwner = <(bool, String, String), String>{};
  final liveOwner = <String, String>{};
  for (final node in nodes) {
    final candidates = eventsByNode[node.id];
    if (candidates == null || candidates.isEmpty) continue;
    for (final session in node.sessions) {
      final owner = _ownerEventId(candidates, session.start, session.end);
      if (owner != null) {
        sessionOwner.putIfAbsent(
          sessionKey(eventById[owner]!, session.id),
          () => owner,
        );
      }
    }
    final started = node.timerStartedAt;
    if (started != null) {
      final owner = _ownerEventId(candidates, started, at);
      if (owner != null) liveOwner[node.id] = owner;
    }
  }
  // Runs cached on an event (older data, or a run that never reached its
  // node) still land on the event they belong to.
  for (final event in visibleEvents) {
    if (event.allDay) continue;
    final candidates = eventsByNode[event.taskId] ?? const <PlannerEvent>[];
    for (final session in event.sessions) {
      final key = sessionKey(event, session.id);
      if (sessionOwner.containsKey(key)) continue;
      sessionOwner[key] =
          _ownerEventId(candidates, session.start, session.end) ?? event.id;
    }
  }
  final emittedSessionIds = <(bool, String, String)>{};
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
      final owner = liveNodeId == null ? null : liveOwner[liveNodeId];
      if (liveNodeId == null) {
        emitLive = true;
      } else if (owner == event.id) {
        // The timer shows on the event whose slot it is running in, so a
        // recording started from any of a task's events appears there.
        emitLive = emittedLiveNodeIds.add(liveNodeId);
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
      // Only the attributed event owns each run; the mirrored copies on the
      // task's other events are skipped. Distinct runs keep their own ids
      // and can each land on a different event.
      final owned = [
        for (final session in sessions)
          if ((sessionOwner[sessionKey(event, session.id)] ?? event.id) ==
              event.id)
            session,
      ];
      final hasMultiple = sessions.length > 1;
      for (final session in owned) {
        if (!emittedSessionIds.add(sessionKey(event, session.id))) continue;
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
      if (owned.isNotEmpty) continue;
      // Every run belongs to a sibling event (the task's other plan block):
      // this block's lane stays empty, Toggl-style — the entry sits on the
      // row it happened during. Accepted entries stay hidden too, since the
      // task already has real recorded time.
      continue;
    }
    if (liveStart != null) continue;

    final matches = acceptedByEvent[event.id];
    if (matches != null) {
      for (final (day, entry) in matches) {
        final end = entry.end.isAfter(entry.start)
            ? entry.end
            : entry.start.add(const Duration(hours: 1));
        blocks.add(
          ReportBlock(
            displayId: reportAcceptedDisplayIdFor(day, entry.id),
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

  for (final (day, entry) in extras) {
    final end = entry.end.isAfter(entry.start)
        ? entry.end
        : entry.start.add(const Duration(hours: 1));
    blocks.add(
      ReportBlock(
        displayId: reportAcceptedDisplayIdFor(day, entry.id),
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

/// Which of a task's plan events a recording belongs to.
///
/// Toggl-style attribution: an entry sits on the row it happened during, so
/// a task planned twice (say Monday 9am and Wednesday 2pm) shows Monday's
/// run on Monday and Wednesday's on Wednesday instead of stacking both on
/// one of them. Picks the event with the largest overlap, then the nearest
/// one; ties break on earliest start, then id, so the choice is stable
/// across rebuilds.
String? _ownerEventId(
  List<PlannerEvent> candidates,
  DateTime start,
  DateTime end,
) {
  if (candidates.isEmpty) return null;
  PlannerEvent? best;
  var bestOverlap = -1;
  var bestGap = -1;
  for (final event in candidates) {
    final overlap = _overlapSeconds(event, start, end);
    final gap = _gapSeconds(event, start, end);
    final better =
        best == null ||
        overlap > bestOverlap ||
        (overlap == bestOverlap && gap < bestGap) ||
        (overlap == bestOverlap &&
            gap == bestGap &&
            (event.start.isBefore(best.start) ||
                (event.start == best.start &&
                    event.id.compareTo(best.id) < 0)));
    if (better) {
      best = event;
      bestOverlap = overlap;
      bestGap = gap;
    }
  }
  return best?.id;
}

int _overlapSeconds(PlannerEvent event, DateTime start, DateTime end) {
  final from = start.isAfter(event.start) ? start : event.start;
  final to = end.isBefore(event.end) ? end : event.end;
  return to.isAfter(from) ? to.difference(from).inSeconds : 0;
}

int _gapSeconds(PlannerEvent event, DateTime start, DateTime end) {
  if (!end.isBefore(event.start) && !start.isAfter(event.end)) return 0;
  if (end.isBefore(event.start)) return event.start.difference(end).inSeconds;
  return start.difference(event.end).inSeconds.abs();
}

/// Event ids that already carry a report, including the sibling events of
/// the same task.
///
/// A task's recorded time belongs to all of its plan events, so copying a
/// sibling event's plan into the report lane would record the same work a
/// second time. The copy badge and [buildPlanCopyEntry] read this set, so
/// multi-event tasks stay protected the way single-event tasks already are.
Set<String> reportedEventIdsFor(
  List<ReportBlock> blocks,
  List<PlannerEvent> visibleEvents,
  List<Node> nodes,
) {
  final ids = <String>{
    for (final block in blocks)
      if (block.eventId != null) block.eventId!,
  };
  if (ids.isEmpty) return ids;
  final nodeForEvent = <String, String>{};
  for (final node in nodes) {
    for (final eventId in [node.calendarEventId, node.sourceEventId]) {
      if (eventId != null) nodeForEvent[eventId] = node.id;
    }
  }
  final reportedNodeIds = <String>{};
  for (final event in visibleEvents) {
    if (!ids.contains(event.id)) continue;
    final taskId = event.taskId;
    if (taskId != null) reportedNodeIds.add(taskId);
    final nodeId = nodeForEvent[event.id];
    if (nodeId != null) reportedNodeIds.add(nodeId);
  }
  if (reportedNodeIds.isEmpty) return ids;
  for (final event in visibleEvents) {
    final taskId = event.taskId;
    if (taskId != null && reportedNodeIds.contains(taskId)) ids.add(event.id);
  }
  return ids;
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
