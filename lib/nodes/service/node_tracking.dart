import 'package:equatable/equatable.dart';

import '../model/node.dart';

class NodeTrackingSelection extends Equatable {
  final Node? recording;
  final List<Node> current;
  final List<Node> previous;
  final List<Node> next;
  final List<Node> unscheduled;

  const NodeTrackingSelection({
    this.recording,
    this.current = const [],
    this.next = const [],
    this.previous = const [],
    this.unscheduled = const [],
  });

  bool get isEmpty =>
      recording == null &&
      current.isEmpty &&
      previous.isEmpty &&
      next.isEmpty &&
      unscheduled.isEmpty;

  @override
  List<Object?> get props => [recording, current, previous, next, unscheduled];
}

/// Whether a schedule block is a real timed work interval that belongs on
/// the time-tracking card: not an all-day marker, not a zero-length point,
/// and bounded within a single calendar day. Multi-day feed windows carry
/// a due date, not work time — offering them as "Happening now" (issue #49)
/// invites tracking time against a date range instead of a session.
bool isTrackableScheduleBlock(ScheduleFacet s) {
  final start = s.start;
  final end = s.end;
  if (start == null || end == null) return false;
  if (s.allDay) return false;
  if (!end.isAfter(start)) return false;
  return start.year == end.year &&
      start.month == end.month &&
      start.day == end.day;
}

/// Picks which nodes to offer on the time-tracking card: the recording
/// node plus scheduled neighbours and a few unscheduled ones. Mirrors the
/// retired task-tracking selection over node schedule blocks.
NodeTrackingSelection selectNodeTracking(
  List<Node> nodes,
  DateTime now, {
  int previousCount = 1,
  int nextCount = 2,
  int unscheduledCount = 3,
}) {
  final open = nodes.where((n) => n.isOpen && !n.isTemplate && n.isTracked).toList();
  Node? recording;
  for (final n in open) {
    if (n.isTracking) {
      recording = n;
      break;
    }
  }
  final recordingId = recording?.id;
  final scheduled = open
      .where((n) =>
          n.hasCalendarBlock &&
          n.schedule != null &&
          isTrackableScheduleBlock(n.schedule!) &&
          n.id != recordingId)
      .toList();
  final current = scheduled
      .where((n) =>
          !n.schedule!.start!.isAfter(now) && n.schedule!.end!.isAfter(now))
      .toList()
    ..sort((a, b) => a.schedule!.start!.compareTo(b.schedule!.start!));
  final currentIds = {for (final n in current) n.id};
  final ended = scheduled
      .where((n) =>
          !n.schedule!.end!.isAfter(now) && !currentIds.contains(n.id))
      .toList()
    ..sort((a, b) => b.schedule!.end!.compareTo(a.schedule!.end!));
  final upcoming = scheduled
      .where((n) =>
          n.schedule!.start!.isAfter(now) && !currentIds.contains(n.id))
      .toList()
    ..sort((a, b) => a.schedule!.start!.compareTo(b.schedule!.start!));
  final unscheduled = open
      .where((n) => !n.hasCalendarBlock && n.id != recordingId)
      .toList()
    ..sort(_byDueThenTitle);
  return NodeTrackingSelection(
    recording: recording,
    current: current,
    previous: ended.take(previousCount).toList().reversed.toList(),
    next: upcoming.take(nextCount).toList(),
    unscheduled: unscheduled.take(unscheduledCount).toList(),
  );
}

int _byDueThenTitle(Node a, Node b) {
  final aDue = a.schedule?.due ?? a.schedule?.start;
  final bDue = b.schedule?.due ?? b.schedule?.start;
  if (aDue == null && bDue == null) {
    return _compareTitles(a.title, b.title);
  }
  if (aDue == null) return 1;
  if (bDue == null) return -1;
  final cmp = aDue.compareTo(bDue);
  if (cmp != 0) return cmp;
  return _compareTitles(a.title, b.title);
}

/// Case-insensitive title compare without allocating two lower-cased
/// strings per comparison (the old code called `toLowerCase()` on every
/// comparator invocation: O(n log n) throwaway strings per build, and this
/// runs every second while tracking).
int _compareTitles(String a, String b) {
  final aLen = a.length;
  final bLen = b.length;
  final len = aLen < bLen ? aLen : bLen;
  for (var i = 0; i < len; i++) {
    var ca = a.codeUnitAt(i);
    var cb = b.codeUnitAt(i);
    // ASCII fast path for case folding.
    if (ca >= 65 && ca <= 90) ca += 32;
    if (cb >= 65 && cb <= 90) cb += 32;
    if (ca != cb) return ca - cb;
  }
  return aLen - bLen;
}
