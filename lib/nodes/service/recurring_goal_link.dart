import '../../common/time/time_session.dart';
import '../bloc/node_cubit.dart';
import '../model/node.dart';
import '../../planner/bloc/calendar_cubit.dart';
import '../../planner/model/planner_event.dart';
import 'event_schedule.dart';

/// Include the feed in the identity: two calendars may expose the same UID.
String? calendarGoalSeriesKey(PlannerEvent event) {
  final series = event.seriesId;
  if (series != null && series.isNotEmpty) {
    return '${event.feedId ?? 'personal'}|series:$series';
  }
  if (event.recurrenceRule.isEmpty) return null;
  final uid = event.sourceUid;
  return '${event.feedId ?? 'personal'}|series:${uid == null || uid.isEmpty ? event.id : uid}';
}

/// One goal occurrence owns the work; the real event supplies its schedule.
/// Never match titles. Existing explicit goal assignments establish a series
/// binding; only unambiguous occurrences in that series can be reconciled.
class RecurringGoalLink {
  const RecurringGoalLink._();

  static int reconcile(
    CalendarCubit calendar,
    NodeCubit nodes, {
    Set<String> protectedNodeIds = const {},
  }) {
    final all = nodes.state;
    final pending = {for (final n in all) n.id: n};
    final byEvent = {for (final e in calendar.state) e.id: e};
    final upserts = <String, Node>{};
    final removals = <String>{};
    final eventUpdates = <String, PlannerEvent>{};
    final referenced = <String>{
      ...protectedNodeIds,
      for (final n in all) ...n.parentIds,
    };
    final bySeries = <String, List<PlannerEvent>>{};
    for (final e in calendar.state) {
      final key = calendarGoalSeriesKey(e);
      if (key != null) (bySeries[key] ??= []).add(e);
    }
    final eventNodes = <String, List<Node>>{};
    for (final n in all) {
      for (final id in {n.sourceEventId, n.calendarEventId}) {
        if (id != null) (eventNodes[id] ??= []).add(n);
      }
    }
    final claims = <String, Set<String>>{};
    for (final template in all.where(
      (n) => n.isTemplate && n.calendarLink?.isEnabled != false,
    )) {
      final keys = <String>{
        if (template.calendarLink != null) template.calendarLink!.seriesKey,
        for (final n in all)
          if (n.parentIds.contains(template.id))
            if (byEvent[n.sourceEventId ?? n.calendarEventId]
                case final PlannerEvent e)
              if (calendarGoalSeriesKey(e) case final String key) key,
      };
      for (final key in keys) {
        (claims[key] ??= {}).add(template.id);
      }
    }
    var linked = 0;
    for (final template in all.where((n) => n.isTemplate && n.money == null)) {
      if (template.calendarLink?.isEnabled == false) continue;
      var key = template.calendarLink?.seriesKey;
      if (key == null) {
        final assignedKeys = <String>{};
        for (final child in all) {
          if (!child.parentIds.contains(template.id)) continue;
          final e = byEvent[child.sourceEventId ?? child.calendarEventId];
          if (e == null) continue;
          final candidate = calendarGoalSeriesKey(e);
          if (candidate != null) assignedKeys.add(candidate);
        }
        if (assignedKeys.length != 1) continue;
        key = assignedKeys.single;
        upserts[template.id] = template.copyWith(
          calendarLink: NodeCalendarLink(seriesKey: key),
        );
      }
      if (claims[key]!.length > 1) {
        upserts.remove(template.id);
        continue;
      }
      final members = bySeries[key] ?? const <PlannerEvent>[];
      final byDay = <String, List<PlannerEvent>>{};
      for (final e in members) {
        (byDay[_day(e.start)] ??= []).add(e);
      }
      final instancesByDay = <String, List<Node>>{};
      for (final n in all) {
        if (n.instanceOfId != template.id || n.schedule?.due == null) continue;
        (instancesByDay[_day(n.schedule!.due!)] ??= []).add(n);
      }
      for (final event in members) {
        if (template.calendarLink?.excludedEventIds.contains(event.id) ??
            false) {
          continue;
        }
        final backing = <Node>[...eventNodes[event.id] ?? const <Node>[]];
        final task = pending[event.taskId];
        if (task != null && !backing.any((n) => n.id == task.id)) {
          backing.add(task);
        }
        final already = backing.where((n) => n.instanceOfId == template.id);
        Node? occurrence;
        if (already.length == 1) {
          // Follow identity, even after moving an event to another day.
          occurrence = pending[already.single.id];
        } else {
          if (byDay[_day(event.start)]!.length != 1) continue;
          final sameDay = instancesByDay[_day(event.start)] ?? const <Node>[];
          if (sameDay.length != 1) continue;
          occurrence = pending[sameDay.single.id];
          if (occurrence == null ||
              occurrence.sourceEventId != null ||
              occurrence.calendarEventId != null) {
            continue;
          }
          // Do not turn previously unassigned past calendar history into work.
          final today = DateTime.now();
          if (event.start.isBefore(
                DateTime(today.year, today.month, today.day),
              ) &&
              !backing.any((n) => n.parentIds.contains(template.id))) {
            continue;
          }
        }
        if (occurrence == null) continue;
        final duplicates = backing
            .where((n) => n.id != occurrence!.id)
            .toList();
        if (duplicates.any(
          (n) =>
              referenced.contains(n.id) ||
              calendar.state.any((e) => e.id != event.id && e.taskId == n.id) ||
              n.instanceOfId != null ||
              n.parentIds.any((id) => id != template.id) ||
              n.money != null ||
              n.anki != null ||
              n.rule != null ||
              n.recurrence != null ||
              n.calendarLink != null,
        )) {
          continue;
        }
        final merged = _merge(occurrence, duplicates, event, key);
        if (merged == null) continue;
        if (merged != occurrence) {
          pending[merged.id] = merged;
          upserts[merged.id] = merged;
          linked++;
        }
        removals.addAll(duplicates.map((n) => n.id));
        final updated = event.copyWith(
          isTask: true,
          taskId: merged.id,
          done: merged.isDone,
          completedAt: merged.completedAt,
          clearCompletedAt: merged.completedAt == null,
          failed: merged.status == NodeStatus.failed,
          sessions: merged.sessions,
          actualStart: merged.actualStart,
          clearActualStart: merged.actualStart == null,
          actualEnd: merged.actualEnd,
          clearActualEnd: merged.actualEnd == null,
          // The task owns the timer; never run a second event timer.
          clearTimerStartedAt: true,
        );
        if (updated != event) eventUpdates[event.id] = updated;
      }
    }
    if (upserts.isEmpty && removals.isEmpty && eventUpdates.isEmpty) return 0;
    // Commit nodes before redirecting events. A rejected graph write must not
    // erase the old backing record or leave an event pointing at a missing id.
    final errors = nodes.writeNodes(
      upserts: upserts.values.toList(),
      silent: true,
    );
    if (errors.isNotEmpty) return 0;
    if (removals.isNotEmpty) {
      nodes.writeNodes(removeIds: removals, silent: true);
    }
    if (eventUpdates.isNotEmpty) {
      calendar.applyState(<PlannerEvent>[
        for (final e in calendar.state) eventUpdates[e.id] ?? e,
      ]);
    }
    return linked;
  }

  static Node? _merge(
    Node occurrence,
    List<Node> duplicates,
    PlannerEvent event,
    String key,
  ) {
    final records = [occurrence, ...duplicates];
    final intervals = <String>{
      for (final n in records)
        if (n.actualStart != null || n.actualEnd != null)
          '${n.actualStart?.toUtc()}|${n.actualEnd?.toUtc()}',
      if (event.actualStart != null || event.actualEnd != null)
        '${event.actualStart?.toUtc()}|${event.actualEnd?.toUtc()}',
    };
    final timers = <DateTime>{
      for (final n in records)
        if (n.timerStartedAt != null) n.timerStartedAt!,
      if (event.timerStartedAt != null) event.timerStartedAt!,
    };
    // Distinct reports or active timers might be separate work. Preserve both.
    if (intervals.length > 1 || timers.length > 1) return null;
    final sessions = <String, TimeSession>{
      for (final n in records)
        for (final session in n.recordedSessions) session.id: session,
      for (final session in event.recordedSessions) session.id: session,
    };
    final statuses = {for (final n in records) n.status};
    if (event.done) statuses.add(NodeStatus.done);
    if (event.failed) statuses.add(NodeStatus.failed);
    final settled = statuses.where((s) => s != NodeStatus.open).toSet();
    if (settled.length > 1) return null;
    final status = settled.isEmpty ? NodeStatus.open : settled.single;
    DateTime? start = event.actualStart;
    DateTime? end = event.actualEnd;
    DateTime? completed = event.completedAt;
    for (final n in records) {
      start ??= n.actualStart;
      end ??= n.actualEnd;
      completed ??= n.completedAt;
    }
    final snapshots = <String, Map<String, dynamic>>{
      ...occurrence.calendarLink?.records ?? const {},
    };
    if (duplicates.isNotEmpty) {
      snapshots.putIfAbsent(occurrence.id, occurrence.toJson);
      for (final n in duplicates) {
        snapshots.putIfAbsent(n.id, n.toJson);
      }
    }
    final notes = <String>{
      for (final n in records)
        if (n.notes != null && n.notes!.trim().isNotEmpty) n.notes!.trim(),
      if (event.notes != null && event.notes!.trim().isNotEmpty)
        event.notes!.trim(),
    };
    final assignees = {
      for (final n in records)
        for (final a in n.assignees) a.id: a,
      for (final a in event.assignees) a.id: a,
    };
    return occurrence.copyWith(
      calendarLink: NodeCalendarLink(seriesKey: key, records: snapshots),
      schedule: scheduleForEvent(event),
      sourceEventId: event.isFromFeed ? event.id : null,
      calendarEventId: event.isFromFeed ? null : event.id,
      feedId: event.feedId,
      classId: event.feedId,
      classLabel: event.classLabel,
      status: status,
      completedAt: status == NodeStatus.done ? completed : null,
      clearCompletedAt: status != NodeStatus.done,
      sessions: sessions.values.toList()
        ..sort((a, b) => a.start.compareTo(b.start)),
      actualStart: start,
      actualEnd: end,
      timerStartedAt: timers.isEmpty ? null : timers.single,
      notes: notes.isEmpty
          ? null
          : notes
                .where(
                  (n) => !notes.any((other) => other != n && other.contains(n)),
                )
                .join('\n\n'),
      assignees: assignees.values.toList(),
      overriddenFields: {
        ...occurrence.overriddenFields,
        'schedule',
        'schedule.due',
        'schedule.start',
        'schedule.end',
      },
    );
  }

  static String _day(DateTime value) {
    final d = value.toLocal();
    return '${d.year}-${d.month}-${d.day}';
  }
}
