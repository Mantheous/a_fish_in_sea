import '../model/node.dart';
import '../../planner/model/planner_event.dart';
import '../../planner/model/feed.dart';
import '../../planner/model/assignment_rule.dart';
import 'node_feed.dart';
import 'event_schedule.dart';

/// Pure feed import: completion and all existing source links survive resync.
List<Node> importFeedNodes(
  List<Node> state,
  List<PlannerEvent> events,
  Feed feed, {
  Set<String> taskOptOutIds = const {},
  List<AssignmentRule> assignmentRules = const [],
}) {
  final now = DateTime.now();
  var base = state;
  if (feed.kind == FeedKind.learningSuite) {
    base = base
        .where(
          (n) =>
              (n.isInstance && n.calendarLink != null) ||
              n.classId != feed.id ||
              n.sourceEventId == null ||
              n.isDone ||
              looksLikeLearningSuiteAssignment(n.title, n.notes),
        )
        .toList();
  }
  final existing = base.map((n) => n.id).toSet();
  final existingSource = base
      .map((n) => n.sourceEventId)
      .whereType<String>()
      .toSet();
  final byEventId = {for (final e in events) e.id: e};
  // One-time healing for the pre-fix exclusive-end bug: LS all-day
  // DTENDs are exclusive per RFC 5545 (DTSTART Oct 12 DTEND Oct 15 is
  // due Oct 14), but imports used to stamp due = DTEND (Oct 15). Move
  // open nodes still sitting exactly on the old base (or old base +
  // their rule shift) to the inclusive base. Hand-edited dues sit
  // anywhere else and are left alone.
  var healed = 0;
  final healedBase = <Node>[];
  for (final n in base) {
    final eventId = n.sourceEventId;
    final s = n.schedule;
    final event = eventId == null ? null : byEventId[eventId];
    if (feed.kind != FeedKind.learningSuite ||
        event == null ||
        s?.due == null ||
        !n.isOpen) {
      healedBase.add(n);
      continue;
    }
    final isWindow =
        event.allDay &&
        event.end.difference(event.start) > const Duration(days: 1);
    if (!isWindow) {
      healedBase.add(n);
      continue;
    }
    final shift = assignmentOffsetFor(
      assignmentRules,
      feedId: feed.id,
      title: n.title,
    );
    final oldBaseDue = shift == 0
        ? event.end
        : event.end.add(Duration(days: shift));
    if (s!.due != oldBaseDue) {
      healedBase.add(n);
      continue;
    }
    final newBaseDue = shift == 0
        ? event.end.subtract(const Duration(days: 1))
        : event.end
              .subtract(const Duration(days: 1))
              .add(Duration(days: shift));
    healed++;
    healedBase.add(
      n.copyWith(
        schedule: s.copyWith(
          due: newBaseDue,
          start: event.start,
          end: event.end,
          allDay: event.allDay,
        ),
      ),
    );
  }
  base = healedBase;
  final imported = <Node>[];
  for (final event in events) {
    if (taskOptOutIds.contains(event.id)) continue;
    if (!isNodeCandidate(event, feed, now)) continue;
    if (existingSource.contains(event.id)) continue;
    if (existing.contains(event.id)) continue;
    // Learning Suite open..due windows (DTSTART..DTEND) are due at the
    // inclusive end of the window: without this every window node would
    // be due (and instantly overdue) on its open date. All-day DTENDs
    // are exclusive per RFC 5545, so the due date is end minus one day
    // (DTSTART Oct 12 DTEND Oct 15 → due Oct 14); timed windows keep
    // the exact end instant. The feed window stays in start/end as
    // truth.
    final isWindow =
        feed.kind == FeedKind.learningSuite &&
        event.allDay &&
        event.end.difference(event.start) > const Duration(days: 1);
    final baseDue = isWindow
        ? event.end.subtract(const Duration(days: 1))
        : event.start;
    // Assignment rules shift the planned deadline (e.g. video quizzes
    // due 2 days early); the feed window stays in start/end as truth.
    final shift = assignmentOffsetFor(
      assignmentRules,
      feedId: feed.id,
      title: event.subject,
    );
    imported.add(
      Node(
        id: event.id,
        title: event.subject,
        notes: event.notes,
        createdAt: DateTime.now(),
        status: event.done ? NodeStatus.done : NodeStatus.open,
        completedAt: event.completedAt,
        schedule: scheduleForEvent(
          event,
          due: shift == 0 ? baseDue : baseDue.add(Duration(days: shift)),
        ),
        sourceEventId: event.id,
        feedId: feed.id,
        classId: feed.id,
        classLabel: event.classLabel,
        assignees: event.assignees,
      ),
    );
  }
  final next = [...base, ...imported];
  if (imported.isNotEmpty || healed > 0 || next.length != state.length) {
    return next;
  }
  return state;
}
