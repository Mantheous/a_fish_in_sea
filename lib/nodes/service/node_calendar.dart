import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';

/// Calendar bridge for unified nodes: schedule blocks render as
/// appointments alongside [PlannerEvent]s. Block ids are prefixed with
/// `node:` so tap/drag/resize handlers can route back to the node.
///
/// Nodes already represented by a real event (personal links via
/// `calendarEventId`, homework via `sourceEventId`) are skipped to avoid
/// double-rendering.

const String nodeBlockPrefix = 'node:';

bool isNodeBlockId(String id) => id.startsWith(nodeBlockPrefix);

String nodeIdFromBlockId(String blockId) =>
    blockId.substring(nodeBlockPrefix.length);

String nodeBlockId(String nodeId) => '$nodeBlockPrefix$nodeId';

/// Synthesized appointments for node schedule blocks.
List<PlannerEvent> nodeCalendarBlocks(List<Node> nodes) {
  final out = <PlannerEvent>[];
  for (final n in nodes) {
    final s = n.schedule;
    if (s == null || !s.hasCalendarBlock) continue;
    if (n.calendarEventId != null || n.sourceEventId != null) continue;
    out.add(PlannerEvent(
      id: nodeBlockId(n.id),
      subject: n.title,
      notes: n.notes,
      start: s.start!,
      end: s.end!,
      allDay: s.allDay,
      classLabel: n.classLabel,
      taskId: n.id,
      isTask: true,
      done: n.isDone,
      assignees: n.assignees,
    ));
  }
  return out;
}

/// One upcoming work slot: where a node is planned on the calendar.
class PlannedSlot {
  final DateTime start;
  final DateTime end;

  const PlannedSlot({required this.start, required this.end});

  @override
  bool operator ==(Object other) =>
      other is PlannedSlot && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'PlannedSlot($start – $end)';
}

/// Upcoming (future, timed) calendar entries per node: how many there are
/// ([counts]) and the earliest one's bounds ([nextSlots]).
class NodePlanOverview {
  const NodePlanOverview({required this.counts, required this.nextSlots});

  final Map<String, int> counts;

  /// Earliest upcoming slot per node; absent when the node has none.
  final Map<String, PlannedSlot> nextSlots;
}

/// Number of future, timed calendar entries linked to each node, keyed by
/// node id. Nodes with no upcoming entries are absent from the map.
///
/// The map is the single source of the app's "planned" meaning: the
/// schedule button tints exactly when a node's count is positive, the
/// Planned/Unplanned task filter keeps exactly the nodes present here, and
/// the tile's "Planned …" line shows the slot from [upcomingNodePlans] — so
/// the button, the filter, and the line can never disagree.
///
/// An entry counts for a node when the calendar displays it as that node's
/// schedule and it starts after [now]:
/// - a linked real event (through the node's `calendarEventId` /
///   `sourceEventId` back-link or the event's `taskId`), or
/// - the node's own schedule block, which renders as a `node:` appointment
///   unless a real event already represents the node ([nodeCalendarBlocks]).
///
/// All-day entries never count: they are dates a thing happens (due dates,
/// imported assignments), not planned work time. One event reachable through
/// several links counts once per node, not once per link.
Map<String, int> futureCalendarEntryCounts(
  List<Node> nodes,
  List<PlannerEvent> events,
  DateTime now,
) =>
    upcomingNodePlans(nodes, events, now).counts;

/// Single pass behind [futureCalendarEntryCounts]: same planned rules, plus
/// the earliest upcoming slot's bounds for each node so tiles can name the
/// day a task is planned on instead of only its times.
NodePlanOverview upcomingNodePlans(
  List<Node> nodes,
  List<PlannerEvent> events,
  DateTime now,
) {
  final countByNode = <String, int>{};
  final nextSlotByNode = <String, PlannedSlot>{};
  if (nodes.isEmpty) {
    return NodePlanOverview(counts: countByNode, nextSlots: nextSlotByNode);
  }

  void record(Node node, DateTime start, DateTime end) {
    countByNode[node.id] = (countByNode[node.id] ?? 0) + 1;
    final current = nextSlotByNode[node.id];
    if (current == null ||
        start.isBefore(current.start) ||
        (start == current.start && end.isAfter(current.end))) {
      nextSlotByNode[node.id] = PlannedSlot(start: start, end: end);
    }
  }

  final nodeById = <String, Node>{};
  final nodeByCalendarEventId = <String, Node>{};
  final nodeBySourceEventId = <String, Node>{};
  for (final n in nodes) {
    nodeById[n.id] = n;
    final calendarId = n.calendarEventId;
    if (calendarId != null) nodeByCalendarEventId[calendarId] = n;
    final sourceId = n.sourceEventId;
    if (sourceId != null) nodeBySourceEventId[sourceId] = n;
  }
  for (final e in events) {
    if (e.allDay || !e.start.isAfter(now)) continue;
    final targets = <Node>{};
    final taskId = e.taskId;
    if (taskId != null) {
      final byTask = nodeById[taskId];
      if (byTask != null) targets.add(byTask);
    }
    final byCalendar = nodeByCalendarEventId[e.id];
    if (byCalendar != null) targets.add(byCalendar);
    final bySource = nodeBySourceEventId[e.id];
    if (bySource != null) targets.add(bySource);
    for (final n in targets) {
      record(n, e.start, e.end);
    }
  }
  for (final n in nodes) {
    // The own block only renders when no real event represents the node.
    if (n.calendarEventId != null || n.sourceEventId != null) continue;
    final s = n.schedule;
    if (s == null || s.allDay || !s.hasCalendarBlock) continue;
    if (!s.start!.isAfter(now)) continue;
    record(n, s.start!, s.end!);
  }
  return NodePlanOverview(
    counts: countByNode,
    nextSlots: nextSlotByNode,
  );
}

/// Shift a node's schedule block by the same delta an event drag applied.
Node shiftNodeBlock(Node node, DateTime fromStart, DateTime toStart) {
  final s = node.schedule;
  if (s == null || s.start == null || s.end == null) return node;
  final delta = toStart.difference(fromStart);
  return node.copyWith(
    schedule: s.copyWith(
      start: s.start!.add(delta),
      end: s.end!.add(delta),
    ),
  );
}
