import 'dart:ui' show Color;

import '../../nodes/model/node.dart';
import '../../nodes/service/node_progress.dart';
import '../../reporting/model/reported_entry.dart';
import '../model/planner_event.dart';
import 'calendar_report.dart' show isReportDisplayId;

/// Toggl-style weekly time attribution, keyed by goal.
///
/// Projects in Toggl become the goal tree here: every logged interval
/// (a stopped timer, a running timer, or an accepted manual entry) is
/// credited to the root goal above its backing node, or to "(no goal)"
/// when nothing links it to the tree. Pure function over the existing
/// timer fields — no new persisted state.
class WeeklyTimeEntry {
  final String title;
  final String? goalId;
  final String goalTitle;
  final DateTime start;
  final DateTime end;
  final bool live;

  const WeeklyTimeEntry({
    required this.title,
    required this.goalId,
    required this.goalTitle,
    required this.start,
    required this.end,
    this.live = false,
  });

  Duration get duration =>
      end.isAfter(start) ? end.difference(start) : Duration.zero;
}

class WeeklyGoalTotal {
  final String? goalId;
  final String title;
  final Duration total;

  const WeeklyGoalTotal({
    required this.goalId,
    required this.title,
    required this.total,
  });
}

class WeeklyTimeReport {
  final Duration weekTotal;
  final List<WeeklyGoalTotal> byGoal;
  final List<WeeklyTimeEntry> entries;

  const WeeklyTimeReport({
    required this.weekTotal,
    required this.byGoal,
    required this.entries,
  });
}

/// Builds the week report for the 7 days starting at [weekStart]
/// (a local-midnight Monday). Durations are clipped to the week window;
/// intervals outside it are skipped. A running timer counts up to [now].
WeeklyTimeReport buildWeeklyTimeReport({
  required List<Node> nodes,
  required List<PlannerEvent> events,
  required Map<String, List<ReportedEntry>> reportsByDay,
  required DateTime weekStart,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  // Calendar-date arithmetic, not 7 x 24h: a DST week is 167 or 169 hours,
  // and adding a fixed duration would drop or include an hour at the edge.
  final weekEnd = DateTime(weekStart.year, weekStart.month, weekStart.day + 7);

  bool overlaps(DateTime start, DateTime end) =>
      end.isAfter(weekStart) && start.isBefore(weekEnd);

  final nodesById = {for (final n in nodes) n.id: n};
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

  final acceptedByEvent = <String, List<ReportedEntry>>{};
  final extras = <ReportedEntry>[];
  for (final entries in reportsByDay.values) {
    for (final entry in entries) {
      // Missed events are the absence of work, and unconfirmed auto entries
      // are guesses: neither counts as logged time (same rule as
      // stats_logic's recorded-time accounting).
      if (entry.auto || entry.status == ReportStatus.missed) continue;
      final eventId = entry.eventId;
      if (eventId == null) {
        extras.add(entry);
      } else {
        acceptedByEvent.putIfAbsent(eventId, () => []).add(entry);
      }
    }
  }

  final out = <WeeklyTimeEntry>[];
  final consumedNodeIds = <String>{};
  // One task's session can be mirrored onto several events (calendar sync
  // copies the node's actuals). Count an identical session once, while
  // keeping genuinely distinct sessions on the same task separate.
  final emittedSessions = <String>{};
  String sessionKey(String backingId, DateTime start, DateTime end) =>
      '$backingId|${start.microsecondsSinceEpoch}|'
      '${end.microsecondsSinceEpoch}';
  final coveredEventIds = <String>{};
  final eventIds = {for (final e in events) e.id};

  Node? backingFor(PlannerEvent event) {
    final linked = nodesByEvent[event.id];
    if (linked != null && linked.isNotEmpty) return linked.first;
    final taskId = event.taskId;
    if (taskId != null) return nodesById[taskId];
    return null;
  }

  ({String? id, String title}) goalFor(Node? backing) {
    if (backing == null) return (id: null, title: noGoalTitle);
    return _rootGoal(backing, nodesById);
  }

  void addIfOverlaps({
    required String title,
    required ({String? id, String title}) goal,
    required DateTime start,
    required DateTime end,
    bool live = false,
  }) {
    if (!overlaps(start, end)) return;
    final clippedStart = start.isBefore(weekStart) ? weekStart : start;
    final clippedEnd = end.isAfter(weekEnd) ? weekEnd : end;
    if (!clippedEnd.isAfter(clippedStart)) return;
    out.add(WeeklyTimeEntry(
      title: title,
      goalId: goal.id,
      goalTitle: goal.title,
      start: clippedStart,
      end: clippedEnd,
      live: live,
    ));
  }

  for (final event in events) {
    if (isReportDisplayId(event.id)) continue;
    final backing = backingFor(event);
    final goal = goalFor(backing);

    // All-day blocks never carry a timed session, but the user can still
    // file an accepted manual report against one, so only skip the
    // timer/actuals passes for them.
    if (!event.allDay) {
      // Only a timed event represents its backing node's own interval;
      // an all-day block must leave the node to the node pass below.
      if (backing != null) consumedNodeIds.add(backing.id);
      final liveStart = event.timerStartedAt ?? _firstTrackingStart(backing);
      if (liveStart != null) {
        final end = at.isAfter(liveStart)
            ? at
            : liveStart.add(const Duration(minutes: 1));
        if (backing != null &&
            !emittedSessions.add(sessionKey(backing.id, liveStart, end))) {
          continue;
        }
        coveredEventIds.add(event.id);
        addIfOverlaps(
          title: event.subject,
          goal: goal,
          start: liveStart,
          end: end,
          live: true,
        );
        continue;
      }

      final reported = _reportedInterval(event, backing);
      if (reported != null) {
        if (backing != null &&
            !emittedSessions.add(
                sessionKey(backing.id, reported.start, reported.end))) {
          continue;
        }
        coveredEventIds.add(event.id);
        addIfOverlaps(
          title: event.subject,
          goal: goal,
          start: reported.start,
          end: reported.end,
        );
        continue;
      }
    }

    final matches = acceptedByEvent[event.id];
    if (matches != null) {
      for (final entry in matches) {
        final end = entry.end.isAfter(entry.start)
            ? entry.end
            : entry.start.add(const Duration(hours: 1));
        addIfOverlaps(
          title: entry.title,
          goal: goal,
          start: entry.start,
          end: end,
        );
      }
    }
  }

  // Timers with no calendar event (schedule-block nodes, plain node
  // timers, or nodes whose event is not in the loaded list): the event
  // pass never sees them, so they are added directly. Nodes already
  // consumed as an event's backing are skipped — their time is counted
  // once, on the event. A linked node is skipped only when that event
  // actually represented its time: an all-day or display-only event never
  // does, so the node's own timer still counts.
  for (final node in nodes) {
    if (consumedNodeIds.contains(node.id)) continue;
    if (node.calendarEventId != null &&
        coveredEventIds.contains(node.calendarEventId)) {
      continue;
    }
    if (node.sourceEventId != null &&
        coveredEventIds.contains(node.sourceEventId)) {
      continue;
    }
    final goal = _rootGoal(node, nodesById);
    final liveStart = node.timerStartedAt;
    if (liveStart != null) {
      final end = at.isAfter(liveStart)
          ? at
          : liveStart.add(const Duration(minutes: 1));
      addIfOverlaps(
        title: node.title,
        goal: (id: goal.id, title: goal.title),
        start: liveStart,
        end: end,
        live: true,
      );
      continue;
    }
    final reported = node.reportedDuration;
    if (reported != null) {
      addIfOverlaps(
        title: node.title,
        goal: (id: goal.id, title: goal.title),
        start: node.actualStart!,
        end: node.actualEnd!,
      );
    }
  }

  // Manual entries pointing at events outside the loaded event list
  // (deleted or out of range): still real logged time, keep them.
  for (final entry in acceptedByEvent.entries) {
    if (coveredEventIds.contains(entry.key)) continue;
    if (eventIds.contains(entry.key)) continue;
    Node? backing;
    final linked = nodesByEvent[entry.key];
    if (linked != null && linked.isNotEmpty) {
      backing = linked.first;
    }
    final goal = goalFor(backing);
    for (final e in entry.value) {
      final end = e.end.isAfter(e.start)
          ? e.end
          : e.start.add(const Duration(hours: 1));
      addIfOverlaps(title: e.title, goal: goal, start: e.start, end: end);
    }
  }

  for (final entry in extras) {
    final end = entry.end.isAfter(entry.start)
        ? entry.end
        : entry.start.add(const Duration(hours: 1));
    addIfOverlaps(
      title: entry.title,
      goal: (id: null, title: noGoalTitle),
      start: entry.start,
      end: end,
    );
  }

  out.sort((a, b) => a.start.compareTo(b.start));

  final totals = <String?, Duration>{};
  final titles = <String?, String>{};
  var weekTotal = Duration.zero;
  for (final entry in out) {
    weekTotal += entry.duration;
    totals[entry.goalId] = (totals[entry.goalId] ?? Duration.zero) +
        entry.duration;
    titles[entry.goalId] = entry.goalTitle;
  }
  final byGoal = <WeeklyGoalTotal>[
    for (final id in totals.keys)
      WeeklyGoalTotal(goalId: id, title: titles[id]!, total: totals[id]!),
  ]..sort((a, b) {
      final cmp = b.total.compareTo(a.total);
      if (cmp != 0) return cmp;
      return a.title.compareTo(b.title);
    });

  return WeeklyTimeReport(
    weekTotal: weekTotal,
    byGoal: byGoal,
    entries: out,
  );
}

const String noGoalTitle = '(no goal)';

DateTime? _firstTrackingStart(Node? backing) => backing?.timerStartedAt;

({DateTime start, DateTime end})? _reportedInterval(
  PlannerEvent event,
  Node? backing,
) {
  if (event.actualStart != null && event.actualEnd != null) {
    final start = event.actualStart!;
    var end = event.actualEnd!;
    if (!end.isAfter(start)) end = start.add(const Duration(minutes: 1));
    return (start: start, end: end);
  }
  final nodeStart = backing?.actualStart;
  final nodeEnd = backing?.actualEnd;
  if (nodeStart != null && nodeEnd != null) {
    var end = nodeEnd;
    if (!end.isAfter(nodeStart)) {
      end = nodeStart.add(const Duration(minutes: 1));
    }
    return (start: nodeStart, end: end);
  }
  return null;
}

/// The root ancestor of [node] following [parentIds] upward (cycle-safe).
/// A node with no ancestors buckets to itself when it is part of the goal
/// tree, otherwise to "(no goal)". Shared children (DAG, several parents)
/// credit the first parent by id so the bucket is deterministic and each
/// interval counts exactly once toward the week total.
({String? id, String title}) _rootGoal(
  Node node,
  Map<String, Node> byId,
) {
  var current = node;
  final seen = <String>{node.id};
  while (current.parentIds.isNotEmpty) {
    final sorted = [...current.parentIds]..sort();
    Node? next;
    for (final parentId in sorted) {
      final parent = byId[parentId];
      if (parent != null && seen.add(parentId)) {
        next = parent;
        break;
      }
    }
    if (next == null) break;
    current = next;
  }
  if (current.id == node.id) {
    return isGoalNode(node)
        ? (id: node.id, title: node.title)
        : (id: null, title: noGoalTitle);
  }
  return (id: current.id, title: current.title);
}

/// Stable palette index for a goal id (Dart's [String.hashCode] is not
/// stable across runs, so the report hashes the id itself).
Color goalColorFor(String? goalId) {
  const personal = Color(0xFF6B8F8A);
  if (goalId == null || goalId.isEmpty) return personal;
  const palette = <Color>[
    Color(0xFFEF6C00),
    Color(0xFF2E7D32),
    Color(0xFF1565C0),
    Color(0xFF6A1B9A),
    Color(0xFFC2185B),
    Color(0xFF00838F),
    Color(0xFFF9A825),
    Color(0xFF4E342E),
    Color(0xFF37474F),
    Color(0xFF7B1FA2),
    Color(0xFF00695C),
    Color(0xFFAD1457),
  ];
  var hash = 0;
  for (var i = 0; i < goalId.length; i++) {
    hash = (hash * 31 + goalId.codeUnitAt(i)) & 0x7fffffff;
  }
  return palette[hash % palette.length];
}

/// Toggl-style compact duration: "45m", "1h 05m", "88h 04m".
String formatWeeklyDuration(Duration duration) {
  final minutes = duration.inMinutes;
  if (minutes < 60) return '${minutes}m';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return '${hours}h ${rest.toString().padLeft(2, '0')}m';
}
