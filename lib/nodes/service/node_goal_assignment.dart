import 'package:a_fish_in_sea/common/time/local_date.dart';
import 'package:a_fish_in_sea/common/undo/revertable_hydrated_cubit.dart';

import '../bloc/node_cubit.dart';
import '../model/node.dart';
import 'node_progress.dart';
import '../../planner/bloc/calendar_cubit.dart';
import '../../planner/model/planner_event.dart';
import 'recurring_goal_link.dart';
import 'node_event_detach.dart';

class NodeGoalAssignment {
  // ── Goal assignment ─────────────────────────────────────────────────
  //
  // Assigning an event to a goal parents its backing node under the goal,
  // so the event's completion/time/money rolls into the goal's progress.
  // Repeating goals bind their calendar series and reconcile matching
  // occurrences, so assignment represents the same work in both views.

  /// True for calendar series (personal repeats, Google masters/instances).
  static bool isRepeatingEvent(PlannerEvent event) =>
      event.recurrenceRule.isNotEmpty || event.isRecurringInstance;

  /// Local grouping key for a repeating series: instances share their
  /// master's id, masters key on their own remote id. Personal repeating
  /// events are singletons (no key) and assign alone.
  static String? seriesKeyOf(PlannerEvent event) {
    if (event.seriesId != null && event.seriesId!.isNotEmpty) {
      return 'series:${event.seriesId}';
    }
    if (event.recurrenceRule.isNotEmpty &&
        event.sourceUid != null &&
        event.sourceUid!.isNotEmpty) {
      return 'series:${event.sourceUid}';
    }
    return null;
  }

  /// The recurring task that already owns [series], when one exists.
  ///
  /// A calendar series has at most one recurring task representation. The
  /// template's generated instances are its canonical work items, so a goal
  /// assignment must attach the template rather than mint a second shadow
  /// task per occurrence (those shadows are what returned after deletion
  /// and flooded the Tasks list with duplicates).
  static Node? recurringOwnerForSeries(NodeCubit nodes, String? series) {
    if (series == null || series.isEmpty) return null;
    for (final node in nodes.state) {
      if (!node.isTemplate || node.money != null) continue;
      final link = node.calendarLink;
      if (link?.isEnabled == false) continue;
      if (link?.seriesKey == series) return node;
    }
    return null;
  }

  /// [recurringOwnerForSeries] for one event, using the same identity the
  /// goal link/reconcile path uses.
  static Node? recurringOwnerForEvent(
    NodeCubit nodes,
    CalendarCubit calendar,
    String eventId,
  ) {
    final event = calendar.byId(eventId);
    if (event == null) return null;
    return recurringOwnerForSeries(nodes, calendarGoalSeriesKey(event));
  }

  /// Every cached event in the seed's series within the same calendar (or
  /// just the seed when it is not part of a series). Mirrors the editor's
  /// series-wide apply, so assignment catches every occurrence.
  static List<PlannerEvent> seriesMembers(
    CalendarCubit calendar,
    PlannerEvent seed,
  ) {
    final key = seriesKeyOf(seed);
    if (key == null) return [seed];
    return [
      for (final e in calendar.state)
        if (e.feedId == seed.feedId && seriesKeyOf(e) == key) e,
    ];
  }

  /// Start of [now]'s calendar day (local). Series tasking treats anything
  /// starting today or later as "future"; anything before is past.
  static DateTime startOfDay(DateTime now) => localDay(now);

  /// True when [event]'s occurrence has not yet passed: it starts on or
  /// after [now]'s calendar day. Task due dates land on the occurrence's
  /// own start day, so this matches the Tasks page's own past/today split
  /// (overdue = due before the start of today).
  static bool isFutureOccurrence(PlannerEvent event, DateTime now) =>
      !event.start.isBefore(startOfDay(now));

  /// The series members that become tasks when a repeating event is marked
  /// as a task: every future occurrence plus the seed itself. The seed is
  /// always included so explicitly picking a past occurrence still acts on
  /// it; the rest of the past is skipped so marking a series that has been
  /// repeating for a while doesn't spam the Tasks list with overdue todos
  /// for every past occurrence.
  static List<PlannerEvent> futureSeriesMembers(
    CalendarCubit calendar,
    PlannerEvent seed, {
    DateTime? now,
  }) {
    final members = seriesMembers(calendar, seed);
    if (members.length <= 1) return members;
    final at = now ?? DateTime.now();
    return [
      for (final e in members)
        if (e.id == seed.id || isFutureOccurrence(e, at)) e,
    ];
  }

  /// The backing node for [eventId]: personal links, homework shadows, or
  /// the `taskId` target. Null when the event was never marked as a task.
  static Node? backingNodeFor(
    NodeCubit nodes,
    CalendarCubit calendar,
    String eventId,
  ) {
    final list = nodes.nodesForEventId(eventId);
    if (list.isNotEmpty) return list.first;
    final event = calendar.byId(eventId);
    final taskId = event?.taskId;
    if (taskId != null) return nodes.byId(taskId);
    return null;
  }

  /// Parents the backing node [nodeId] under [goalId]. Idempotent: already
  /// assigned returns null (success, nothing to do). Validation (cycles,
  /// instance rules) comes from [NodeCubit.reparent] and is returned as an
  /// error string.
  static String? assignNodeToGoal(
    NodeCubit nodes,
    String nodeId,
    String goalId,
  ) {
    final node = nodes.byId(nodeId);
    if (node == null) return 'Task not found.';
    final goal = nodes.byId(goalId);
    if (goal == null) return 'Goal not found.';
    if (nodeId == goalId) return 'An item cannot be its own parent.';
    if (goal.instanceOfId != null) {
      return 'Generated instances cannot have children of their own. '
          'Parent to the template (${goal.instanceOfId}) instead.';
    }
    if (node.parentIds.contains(goalId)) return null;
    return nodes.reparent(nodeId, [...node.parentIds, goalId]);
  }

  /// Removes [goalId] from [nodeId]'s parents. Already-removed is success.
  static String? unassignNodeFromGoal(
    NodeCubit nodes,
    String nodeId,
    String goalId,
  ) {
    final node = nodes.byId(nodeId);
    if (node == null) return 'Task not found.';
    if (!node.parentIds.contains(goalId)) return null;
    return nodes.reparent(
      nodeId,
      node.parentIds.where((p) => p != goalId).toList(),
    );
  }

  /// Removes [goalId] from the backing node(s) of [eventId]. With
  /// [includeSeries] the removal covers the seed plus its future series
  /// members (mirroring [assignEventToGoal]'s targets); otherwise only
  /// this occurrence. Batched into one emit. Returns the number of
  /// backing nodes actually unparented plus the first error, if any.
  static ({String? error, int removed}) unassignEventFromGoal(
    CalendarCubit calendar,
    NodeCubit nodes,
    String eventId,
    String goalId, {
    bool includeSeries = true,
    DateTime? now,
  }) {
    final seed = calendar.byId(eventId);
    if (seed == null) return (error: 'Event not found.', removed: 0);
    var targets = [seed];
    if (includeSeries) {
      final members = futureSeriesMembers(calendar, seed, now: now);
      if (members.isNotEmpty) targets = members;
    }
    final goal = nodes.byId(goalId);
    if (includeSeries &&
        goal?.calendarLink != null &&
        goal!.calendarLink!.seriesKey == calendarGoalSeriesKey(seed)) {
      final link = goal.calendarLink!;
      nodes.updateNode(
        goal.copyWith(
          calendarLink: NodeCalendarLink(
            seriesKey: link.seriesKey,
            records: link.records,
            excludedEventIds: link.excludedEventIds,
            isEnabled: false,
          ),
        ),
      );
    }
    // A series assignment attaches the recurring template, not each event.
    // Remove that single edge so every generated instance leaves the goal.
    final owner = includeSeries
        ? recurringOwnerForSeries(nodes, calendarGoalSeriesKey(seed))
        : null;
    if (owner != null &&
        owner.id != goalId &&
        owner.parentIds.contains(goalId)) {
      final error = unassignNodeFromGoal(nodes, owner.id, goalId);
      return (error: error, removed: error == null ? 1 : 0);
    }
    final linked = [
      for (final event in targets)
        if (backingNodeFor(nodes, calendar, event.id) case final Node n)
          if (n.instanceOfId == goalId && n.calendarLink != null) event,
    ];
    if (linked.isNotEmpty) {
      RevertableHydratedCubit.atomic([nodes, calendar], () {
        nodes.emitSilent(
          detachEventNodes(nodes.state, linked.map((e) => e.id).toSet()),
        );
        final updates = <PlannerEvent>[];
        final feedEvents = <PlannerEvent>[];
        final personalEvents = <PlannerEvent>[];
        for (final e in linked) {
          final detached = e.copyWith(clearTaskId: true);
          if (e.isFromFeed) {
            feedEvents.add(detached);
          } else {
            personalEvents.add(detached);
          }
        }
        nodes.ensureNodesForFeedEvents(feedEvents);
        final ids = nodes.upsertLinkedNodesForEvents(personalEvents);
        for (final e in linked) {
          updates.add(e.copyWith(taskId: ids[e.id] ?? e.id));
        }
        calendar.updateEvents(updates);
      });
      return (error: null, removed: linked.length);
    }
    final toUnparent = <String, Node>{};
    for (final event in targets) {
      final backing = backingNodeFor(nodes, calendar, event.id);
      if (backing == null) continue;
      if (!backing.parentIds.contains(goalId)) continue;
      toUnparent.putIfAbsent(
        backing.id,
        () => backing.copyWith(
          parentIds: backing.parentIds.where((p) => p != goalId).toList(),
        ),
      );
    }
    if (toUnparent.isEmpty) return (error: null, removed: 0);
    final writeErrors = nodes.writeNodes(upserts: toUnparent.values.toList());
    var removed = 0;
    String? firstError;
    for (final entry in toUnparent.entries) {
      final err = writeErrors[entry.key];
      if (err != null) {
        firstError ??= err;
        continue;
      }
      removed++;
    }
    if (removed == 0) return (error: firstError, removed: 0);
    return (error: firstError, removed: removed);
  }

  /// Assigns [eventId] (plus its future series members when
  /// [includeSeries]) to the goal [goalId]. Events not yet marked as tasks
  /// are marked first so a backing node exists. Past occurrences are
  /// skipped (the seed itself is always included): assigning a series that
  /// has been repeating for a while must not flood the Tasks list with an
  /// overdue todo per past occurrence. Returns the number of newly
  /// parented backing nodes plus the first error encountered, if any.
  ///
  /// Batched into at most four emits (one per phase below): the old
  /// per-member loop snapshotted the whole store, rebuilt, persisted, and
  /// recorded an undo entry per occurrence — hundreds of full-store
  /// snapshots that freeze then kill the tab on large stores.
  static ({String? error, int assigned}) assignEventToGoal(
    CalendarCubit calendar,
    NodeCubit nodes,
    String eventId,
    String goalId, {
    bool includeSeries = true,
    DateTime? now,
  }) {
    late ({String? error, int assigned}) result;
    RevertableHydratedCubit.atomic([nodes, calendar], () {
      result = _assignEventToGoal(
        calendar,
        nodes,
        eventId,
        goalId,
        includeSeries: includeSeries,
        now: now,
      );
      if (result.error == null) {
        final goal = nodes.byId(goalId);
        final seed = calendar.byId(eventId);
        final key = seed == null ? null : calendarGoalSeriesKey(seed);
        if (goal != null && goal.isTemplate && key != null) {
          final old = goal.calendarLink;
          final targets = includeSeries
              ? futureSeriesMembers(calendar, seed!, now: now)
              : [seed!];
          final ids = targets.map((e) => e.id).toSet();
          nodes.updateNode(
            goal.copyWith(
              calendarLink: NodeCalendarLink(
                seriesKey: old?.isEnabled == false
                    ? key
                    : old?.seriesKey ?? key,
                records: old?.records ?? const {},
                excludedEventIds: {...?old?.excludedEventIds}..removeAll(ids),
              ),
            ),
          );
        }
        // The app coordinator reconciles after both stores settle, with
        // transaction references available so no assigned record is removed.
      }
    });
    return result;
  }

  static ({String? error, int assigned}) _assignEventToGoal(
    CalendarCubit calendar,
    NodeCubit nodes,
    String eventId,
    String goalId, {
    bool includeSeries = true,
    DateTime? now,
  }) {
    final seed = calendar.byId(eventId);
    if (seed == null) return (error: 'Event not found.', assigned: 0);
    if (seed.id.startsWith('node:') || seed.id.startsWith('report:')) {
      return (error: 'That tile cannot be assigned to a goal.', assigned: 0);
    }
    final goal = nodes.byId(goalId);
    if (goal == null) return (error: 'Goal not found.', assigned: 0);
    if (!isGoalNode(goal)) {
      return (
        error:
            'Pick a goal from the Nodes page — '
            'imported homework cannot have children assigned.',
        assigned: 0,
      );
    }
    final series = calendarGoalSeriesKey(seed);
    if (goal.isTemplate &&
        goal.calendarLink?.isEnabled == true &&
        series != null &&
        goal.calendarLink!.seriesKey != series) {
      return (
        error:
            'This goal is connected to another calendar series. Unassign that series first.',
        assigned: 0,
      );
    }
    // This series already has a recurring task. Attach that template to the
    // goal — its generated instances are the work — instead of creating one
    // event shadow per occurrence. A template goal keeps the old behavior:
    // it binds the series through its own calendarLink.
    final owner = goal.isTemplate
        ? null
        : recurringOwnerForSeries(nodes, series);
    if (owner != null && owner.id != goal.id) {
      if (includeSeries) {
        final already = owner.parentIds.contains(goal.id);
        final error = already
            ? null
            : assignNodeToGoal(nodes, owner.id, goal.id);
        return (error: error, assigned: error == null && !already ? 1 : 0);
      }
      final occurrence = backingNodeFor(nodes, calendar, eventId);
      if (occurrence != null && occurrence.id != owner.id) {
        final already = occurrence.parentIds.contains(goal.id);
        final error = already
            ? null
            : assignNodeToGoal(nodes, occurrence.id, goal.id);
        return (error: error, assigned: error == null && !already ? 1 : 0);
      }
    }
    var targets = [seed];
    if (includeSeries) {
      final members = futureSeriesMembers(calendar, seed, now: now);
      if (members.isNotEmpty) targets = members;
    }
    // Phase 1: personal backing nodes, batched. Non-task members are
    // marked first via the isTask copy, mirroring the single-write lookup
    // order (taskId link, calendar-event link, create).
    final personalInputs = <PlannerEvent>[];
    for (final event in targets) {
      if (event.isFromFeed) continue;
      final live = calendar.byId(event.id) ?? event;
      personalInputs.add(event.isTask ? live : live.copyWith(isTask: true));
    }
    final linkedIds = nodes.upsertLinkedNodesForEvents(personalInputs);
    // Phase 2: calendar marks + task links, batched. Mirrors
    // [CalendarCubit.setTaskLink]'s skip rule (same taskId and already a
    // task means nothing to do).
    final calUpdates = <PlannerEvent>[];
    for (final event in targets) {
      final live = calendar.byId(event.id) ?? event;
      if (!event.isTask) {
        if (event.isFromFeed) {
          if (!live.isTask) calUpdates.add(live.copyWith(isTask: true));
        } else {
          final nodeId = linkedIds[event.id];
          if (nodeId != null && !(live.taskId == nodeId && live.isTask)) {
            calUpdates.add(live.copyWith(isTask: true, taskId: nodeId));
          }
        }
      } else if (!event.isFromFeed && live.taskId == null) {
        final nodeId = linkedIds[event.id];
        if (nodeId != null) {
          calUpdates.add(live.copyWith(isTask: true, taskId: nodeId));
        }
      }
    }
    calendar.updateEvents(calUpdates);
    // Phase 3: feed backing shadows, batched.
    final feedInputs = <PlannerEvent>[];
    for (final event in targets) {
      if (!event.isFromFeed) continue;
      final live = calendar.byId(event.id) ?? event;
      feedInputs.add(event.isTask ? live : live.copyWith(isTask: true));
    }
    nodes.ensureNodesForFeedEvents(feedInputs);
    // Phase 4: parent every backing under the goal, batched. Same guards
    // as [assignNodeToGoal], in the same order (self, generated-goal,
    // already-parented); cycle/relation errors come back from the batch
    // write's validation, which runs the same validators.
    var assigned = 0;
    String? firstError;
    final toParent = <String, Node>{};
    for (final event in targets) {
      final backing = backingNodeFor(nodes, calendar, event.id);
      if (backing == null) {
        firstError ??= 'Could not link “${event.subject}”.';
        continue;
      }
      if (backing.id == goalId) {
        firstError ??= 'An item cannot be its own parent.';
        continue;
      }
      if (goal.instanceOfId != null) {
        firstError ??=
            'Generated instances cannot have children of their '
            'own. Parent to the template (${goal.instanceOfId}) instead.';
        continue;
      }
      if (backing.parentIds.contains(goalId)) continue;
      toParent.putIfAbsent(
        backing.id,
        () => backing.copyWith(parentIds: [...backing.parentIds, goalId]),
      );
    }
    final writeErrors = nodes.writeNodes(upserts: toParent.values.toList());
    for (final entry in toParent.entries) {
      final err = writeErrors[entry.key];
      if (err != null) {
        firstError ??= err;
        continue;
      }
      assigned++;
    }
    if (assigned == 0 && firstError == null) {
      return (error: null, assigned: 0);
    }
    if (assigned == 0) return (error: firstError, assigned: 0);
    return (error: firstError, assigned: assigned);
  }
}
