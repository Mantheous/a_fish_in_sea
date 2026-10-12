import 'package:a_fish_in_sea/common/undo/revertable_hydrated_cubit.dart';
import 'package:a_fish_in_sea/finances/model/budget.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';
import 'package:a_fish_in_sea/finances/model/recurring_rule.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/goals/model/goal.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/model/task.dart';

import '../model/node.dart';
import '../model/node_relations.dart';
import '../service/node_feed.dart';
import '../service/node_progress.dart';
import '../service/node_tree_ops.dart';

/// Unified goals/tasks store. One DAG of [Node]s replaces Goal + Task +
/// Budget + Expense; transactions and calendar events stay separate and
/// link in directly (no tags anywhere).
class NodeCubit extends RevertableHydratedCubit<List<Node>> {
  NodeCubit() : super(const []);

  // ── Lookups (indexed; rebuilt once per state change, not per tile) ────

  List<Node>? _indexSource;
  Map<String, Node>? _byIdIndex;
  Map<String, List<Node>>? _eventIndex;

  Map<String, Node> get _byIdMap {
    final s = state;
    if (!identical(s, _indexSource) || _byIdIndex == null) {
      _byIdIndex = {for (final n in s) n.id: n};
      _eventIndex = null;
      _indexSource = s;
    }
    return _byIdIndex!;
  }

  Map<String, List<Node>> get _byEventId {
    _byIdMap; // ensures _indexSource is fresh
    var idx = _eventIndex;
    if (idx == null) {
      idx = <String, List<Node>>{};
      for (final n in state) {
        final c = n.calendarEventId;
        if (c != null) (idx[c] ??= []).add(n);
        final src = n.sourceEventId;
        if (src != null) (idx[src] ??= []).add(n);
      }
      _eventIndex = idx;
    }
    return idx;
  }

  void _invalidateIndex() {
    _indexSource = null;
    _byIdIndex = null;
    _eventIndex = null;
  }

  @override
  void emit(List<Node> state) {
    _invalidateIndex();
    super.emit(state);
  }

  Node? byId(String id) => _byIdMap[id];

  List<Node> childrenOf(String parentId) =>
      state.where((n) => n.parentIds.contains(parentId)).toList();

  List<Node> get roots =>
      state.where((n) => n.parentIds.isEmpty).toList();

  List<Node> instancesOf(String templateId) =>
      state.where((n) => n.instanceOfId == templateId).toList();

  /// Emit without an undo record. For system writes (feed sync, instance
  /// generation) that must not pollute the user's undo history.
  void emitSilent(List<Node> next) => emit(next);

  // ── Batched writes ────────────────────────────────────────────────
  //
  // Series-wide operations (whole-series edit, assign-series-to-goal)
  // touch every occurrence at once. Looping the single-write methods
  // above snapshots the whole store, rebuilds, persists, and records an
  // undo entry per member — hundreds of full-store snapshots that freeze
  // then kill the tab on large stores (2730 events / 1880 nodes). These
  // batch every member into ONE undoable emit (one undo record, one
  // rebuild, one persist). Per-member decisions mirror the single-write
  // methods exactly (see the equivalence tests); the only difference is
  // that intermediate states are never emitted, so mid-loop reads below
  // go through the evolving [pending] map instead of the cubit.

  /// Saves many nodes (updates by id, adds missing) plus removals as ONE
  /// undoable emit. Nodes failing validation are skipped; their errors
  /// are returned keyed by node id. This mirrors the single-write
  /// callers, which ignore those errors and continue with the rest.
  /// With [silent] the write emits without an undo record, mirroring
  /// [removeNodesForEvent].
  Map<String, String> writeNodes({
    List<Node> upserts = const [],
    Set<String> removeIds = const {},
    bool silent = false,
  }) {
    final errors = <String, String>{};
    final valid = <Node>[];
    for (final n in upserts) {
      final unboundedError = validateUnbounded(n);
      if (unboundedError != null) {
        errors[n.id] = unboundedError;
        continue;
      }
      final error = validateParents(n, n.parentIds);
      if (error != null) {
        errors[n.id] = error;
        continue;
      }
      valid.add(n);
    }
    if (valid.isEmpty && removeIds.isEmpty) return errors;
    final byId = {for (final n in valid) n.id: n};
    final next = <Node>[];
    for (final n in state) {
      if (removeIds.contains(n.id)) continue;
      next.add(byId[n.id] ?? n);
    }
    final known = {for (final n in state) n.id};
    for (final n in valid) {
      if (!known.contains(n.id)) next.add(n);
    }
    if (silent) {
      emit(next);
    } else {
      emitChange(next);
    }
    return errors;
  }

  /// Nodes linked to any of [eventIds] within [byId] (mirrors [_byEventId]
  /// over an evolving batch map instead of the cubit state).
  static List<Node> _nodesForEventIn(
    Map<String, Node> byId,
    String eventId,
  ) =>
      [
        for (final n in byId.values)
          if (n.calendarEventId == eventId || n.sourceEventId == eventId) n,
      ];

  /// Batch version of [ensureNodeForFeedEvent]: ensures a homework-style
  /// backing node for every event as ONE emit. Mirrors the single-write
  /// decisions exactly (including the feedId null early-out).
  void ensureNodesForFeedEvents(List<PlannerEvent> events) {
    if (events.isEmpty) return;
    final pending = <String, Node>{for (final n in state) n.id: n};
    final upserts = <Node>[];
    void put(Node n) {
      pending[n.id] = n;
      upserts.add(n);
    }

    for (final event in events) {
      if (event.feedId == null) continue;
      final existing = _nodesForEventIn(pending, event.id);
      if (existing.isEmpty) {
        final now = DateTime.now();
        put(Node(
          id: event.id,
          title: event.subject,
          notes: event.notes,
          createdAt: now,
          status: event.done ? NodeStatus.done : NodeStatus.open,
          completedAt: event.completedAt,
          schedule: ScheduleFacet(
            due: event.start,
            start: event.start,
            end: event.end,
          ),
          sourceEventId: event.id,
          feedId: event.feedId,
          classId: event.feedId,
          classLabel: event.classLabel,
          assignees: event.assignees,
        ));
        continue;
      }
      final want = event.failed
          ? NodeStatus.failed
          : (event.done ? NodeStatus.done : NodeStatus.open);
      for (final node in existing) {
        if (node.status != want ||
            node.completedAt != event.completedAt ||
            !_sameAssignees(node.assignees, event.assignees)) {
          put(node.copyWith(
            status: want,
            completedAt: event.completedAt,
            clearCompletedAt: !event.done,
            assignees: event.assignees,
          ));
        }
      }
    }
    writeNodes(upserts: upserts);
  }

  /// Mirrors [upsertLinkedNodeForEvent]'s title/notes/schedule/status sync
  /// for one personal linked node.
  static Node _syncLinkedNode(Node linked, PlannerEvent event) {
    final hasNotes = (event.notes ?? '').trim().isNotEmpty;
    // Imported homework keeps the due date its feed gave it: the block
    // says when the user plans to work, which is not when the
    // assignment is due. Personal nodes have no such date, so their
    // due stays the event's own start (the previous behaviour).
    final due = linked.sourceEventId != null
        ? (linked.schedule?.due ?? event.start)
        : event.start;
    return linked.copyWith(
      title: event.subject,
      notes: hasNotes ? event.notes!.trim() : null,
      clearNotes: !hasNotes,
      schedule: ScheduleFacet(
        due: due,
        start: event.start,
        end: event.end,
      ),
      status: event.done ? NodeStatus.done : NodeStatus.open,
      completedAt: event.completedAt,
      clearCompletedAt: !event.done || event.completedAt == null,
      assignees: event.assignees,
    );
  }

  /// Batch version of [upsertLinkedNodeForEvent]: resolves or creates the
  /// personal backing node for every event as ONE emit. Returns the
  /// event id → node id map. Mirrors the single-write lookup order
  /// (taskId link, then calendar-event link, then create) exactly.
  Map<String, String> upsertLinkedNodesForEvents(List<PlannerEvent> events) {
    final ids = <String, String>{};
    if (events.isEmpty) return ids;
    final pending = <String, Node>{for (final n in state) n.id: n};
    final upserts = <Node>[];
    void put(Node n) {
      pending[n.id] = n;
      upserts.add(n);
    }

    for (final event in events) {
      if (event.taskId != null) {
        final linked = pending[event.taskId!];
        if (linked != null) {
          put(_syncLinkedNode(linked, event));
          ids[event.id] = linked.id;
          continue;
        }
      }
      Node? byCalendar;
      for (final n in pending.values) {
        if (n.calendarEventId == event.id) {
          byCalendar = n;
          break;
        }
      }
      if (byCalendar != null) {
        put(_syncLinkedNode(byCalendar, event));
        ids[event.id] = byCalendar.id;
        continue;
      }
      final id = 'node:${event.id}';
      put(Node(
        id: id,
        title: event.subject,
        notes: event.notes,
        createdAt: DateTime.now(),
        status: event.done ? NodeStatus.done : NodeStatus.open,
        completedAt: event.completedAt,
        schedule: ScheduleFacet(
          due: event.start,
          start: event.start,
          end: event.end,
        ),
        classLabel: event.classLabel,
        calendarEventId: event.id,
        assignees: event.assignees,
      ));
      ids[event.id] = id;
    }
    writeNodes(upserts: upserts);
    return ids;
  }

  /// Batch version of [setDoneForEvent]: mirrors completion onto every
  /// backing node of every listed event as ONE emit. Same skip rules.
  void setDoneForEventIds(
    Set<String> eventIds, {
    required bool done,
    DateTime? completedAt,
  }) {
    if (eventIds.isEmpty) return;
    final pending = <String, Node>{for (final n in state) n.id: n};
    final upserts = <Node>[];
    for (final eventId in eventIds) {
      for (final node in _nodesForEventIn(pending, eventId)) {
        if (node.isDone == done &&
            (done || node.completedAt == null) &&
            (node.completedAt == completedAt ||
                (!done && completedAt == null))) {
          continue;
        }
        final next = node.copyWith(
          status: done ? NodeStatus.done : NodeStatus.open,
          completedAt: completedAt,
          clearCompletedAt: !done,
        );
        pending[next.id] = next;
        upserts.add(next);
      }
    }
    writeNodes(upserts: upserts);
  }

  /// Batch version of [removeNodesForEvent]: deletes every node backing
  /// any listed event as ONE emit. Pass [silent] to skip the undo
  /// record, exactly like the single version.
  void removeNodesForEventIds(Set<String> eventIds, {bool silent = false}) {
    if (eventIds.isEmpty) return;
    final pending = <String, Node>{for (final n in state) n.id: n};
    final remove = <String>{};
    for (final eventId in eventIds) {
      for (final node in _nodesForEventIn(pending, eventId)) {
        remove.add(node.id);
      }
    }
    writeNodes(removeIds: remove, silent: silent);
  }

  // ── Queue getters (mirror the old TaskCubit home/queue semantics) ───

  DateTime? _queueDate(Node n) => n.schedule?.due ?? n.schedule?.start;

  int _byDueThenCreated(Node a, Node b) {
    final aDue = _queueDate(a);
    final bDue = _queueDate(b);
    if (aDue == null && bDue == null) {
      return a.createdAt.compareTo(b.createdAt);
    }
    if (aDue == null) return 1;
    if (bDue == null) return -1;
    final cmp = aDue.compareTo(bDue);
    return cmp != 0 ? cmp : a.createdAt.compareTo(b.createdAt);
  }

  /// Open nodes sorted queue-first, done by recency — the To-Do list.
  /// Templates (dateless prescriptions) are excluded; their instances
  /// carry the dates. Unbounded goals are excluded too: they never
  /// complete, so they would sit in the list forever.
  List<Node> get openNodes {
    final open = state
        .where((n) => n.isOpen && !n.isTemplate && !n.isUnbounded)
        .toList()
      ..sort(_byDueThenCreated);
    final done = state.where((n) => n.isDone).toList()
      ..sort(_byCompletedDesc);
    return [...open, ...done];
  }

  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  static int _byCompletedDesc(Node a, Node b) =>
      (b.completedAt ?? _epoch).compareTo(a.completedAt ?? _epoch);

  List<Node> get overdueAndToday => overdueAndTodayAt(DateTime.now());

  List<Node> overdueAndTodayAt(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    return state.where((n) {
      if (!n.isOpen || n.isTemplate || n.isUnbounded) return false;
      final due = n.schedule?.due;
      if (due == null) return false;
      final day = DateTime(due.year, due.month, due.day);
      return day.isBefore(tomorrow);
    }).toList()
      ..sort(_byDueThenCreated);
  }

  /// Open, non-template nodes with a due date strictly before the start
  /// of today. Powers the Tasks page "Overdue" filter.
  List<Node> get overdue => overdueAt(DateTime.now());

  List<Node> overdueAt(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return state.where((n) {
      if (!n.isOpen || n.isTemplate || n.isUnbounded) return false;
      final due = n.schedule?.due;
      if (due == null) return false;
      return due.isBefore(today);
    }).toList()
      ..sort(_byDueThenCreated);
  }

  /// Open, non-template nodes due on today's calendar day. Powers the
  /// Tasks page "Today" filter. Overdue items are excluded — they have
  /// their own filter — so nothing is counted twice.
  List<Node> get dueToday => dueTodayAt(DateTime.now());

  List<Node> dueTodayAt(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    return state.where((n) {
      if (!n.isOpen || n.isTemplate || n.isUnbounded) return false;
      final due = n.schedule?.due;
      if (due == null) return false;
      return !due.isBefore(today) && due.isBefore(tomorrow);
    }).toList()
      ..sort(_byDueThenCreated);
  }

  /// Open nodes due in the rest of the calendar week: start of today
  /// through Sunday (inclusive). The window shrinks as the week runs
  /// out — on Sunday it spans to next Sunday, on Saturday it covers
  /// just the weekend. Overdue items are excluded; they belong to the
  /// past, not to this week. Used by the Home dashboard's week section
  /// and the Tasks page week highlight.
  List<Node> get dueThisWeek => dueThisWeekAt(DateTime.now());

  List<Node> dueThisWeekAt(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    // DateTime.weekday: Monday = 1 … Sunday = 7. Days until Sunday;
    // Sunday itself rolls forward to next Sunday.
    var daysToSunday = DateTime.sunday - now.weekday;
    if (daysToSunday <= 0) daysToSunday += 7;
    // +1 so a due date on Sunday itself is still inside the window.
    final endExclusive = today.add(Duration(days: daysToSunday + 1));
    return state.where((n) {
      if (!n.isOpen || n.isTemplate || n.isUnbounded) return false;
      final due = n.schedule?.due;
      if (due == null) return false;
      return !due.isBefore(today) && due.isBefore(endExclusive);
    }).toList()
      ..sort(_byDueThenCreated);
  }

  // ── Validation (DAG) ────────────────────────────────────────────────

  /// Returns an error string, or null when [parentIds] is acceptable.
  ///
  /// Two layers, deliberately separate:
  ///
  ///  - **Graph shape** (here): self-parenting, duplicates, unknown ids,
  ///    and cycles that run through [Node.parentIds] alone. These are
  ///    answerable without knowing what the nodes *mean*.
  ///  - **Structural relations** ([validateNodeRelations]): everything
  ///    expressed through `instanceOfId` rather than `parentIds`, which
  ///    the cycle walk below cannot see.
  ///
  /// [checkRelations] exists because these rules can refuse a state that
  /// old data already satisfies. Running them on every write would make
  /// such a node permanently un-editable — every ordinary edit (toggling
  /// done, starting the timer) would come back with a structural error the
  /// caller cannot act on, and the edit would be lost. So the relation
  /// rules only apply when the structure that *defines* the relation is
  /// actually being changed.
  String? validateParents(
    Node draft,
    List<String> parentIds, {
    bool checkRelations = true,
  }) {
    final seenParents = <String>{};
    for (final p in parentIds) {
      if (p == draft.id) return 'A node cannot be its own parent.';
      if (!seenParents.add(p)) return 'Duplicate parent.';
      if (byId(p) == null) return 'Parent node not found.';
    }
    // Cycle check: none of the proposed parents may already descend
    // from the draft.
    final descendants = descendantIds(draft.id, state);
    for (final p in parentIds) {
      if (descendants.contains(p)) {
        return 'That parent would create a cycle.';
      }
    }
    // Structural relations, but only when the caller is actually changing
    // the structure they describe (see [checkRelations]).
    if (checkRelations && _relationsChanged(draft, parentIds)) {
      final relationError = validateNodeRelations(
        draft: draft,
        all: state,
        parentIds: parentIds,
      );
      if (relationError != null) return relationError;
    }
    return null;
  }

  /// True when [draft]'s parent/instance structure differs from what is
  /// stored. Identity of the two relations, not their contents: if a node
  /// was already parented wrongly, editing it is how it gets fixed.
  bool _relationsChanged(Node draft, List<String> parentIds) {
    final stored = byId(draft.id);
    if (stored == null) return true;
    if (stored.instanceOfId != draft.instanceOfId) return true;
    if (stored.parentIds.length != parentIds.length) return true;
    for (var i = 0; i < parentIds.length; i++) {
      if (stored.parentIds[i] != parentIds[i]) return true;
    }
    return false;
  }

  // ── CRUD ────────────────────────────────────────────────────────────

  String? addNode(Node node) {
    if (byId(node.id) != null) return 'A node with that id exists.';
    final unboundedError = validateUnbounded(node);
    if (unboundedError != null) return unboundedError;
    final error = validateParents(node, node.parentIds);
    if (error != null) return error;
    emitChange([...state, node]);
    return null;
  }

  String? updateNode(Node updated) {
    if (byId(updated.id) == null) return 'Node not found.';
    final unboundedError = validateUnbounded(updated);
    if (unboundedError != null) return unboundedError;
    // Fast path: status/completion/content edits leave the DAG structure
    // untouched. Re-running validateParents here rebuilds the full parent
    // index plus a descendant walk (O(n)) on every checkbox tap.
    final current = byId(updated.id)!;
    if (!_sameStructure(current, updated)) {
      final error = validateParents(updated, updated.parentIds);
      if (error != null) return error;
    }
    emitChange(
        state.map((n) => n.id == updated.id ? updated : n).toList());
    return null;
  }

  /// Structural fields guarded by [validateParents]: parent links, the
  /// template link, and the recurrence that makes a node a template.
  /// Everything else (status, dates, money, text) cannot introduce a cycle.
  static bool _sameStructure(Node a, Node b) {
    if (a.instanceOfId != b.instanceOfId) return false;
    if (a.recurrence != b.recurrence) return false;
    final pa = a.parentIds;
    final pb = b.parentIds;
    if (!identical(pa, pb)) {
      if (pa.length != pb.length) return false;
      for (var i = 0; i < pa.length; i++) {
        if (pa[i] != pb[i]) return false;
      }
    }
    return true;
  }

  String? reparent(String id, List<String> parentIds) {
    final node = byId(id);
    if (node == null) return 'Node not found.';
    return updateNode(node.copyWith(parentIds: parentIds));
  }

  // ── Goal-tree building (issue #4: complex goal trees) ───────────────
  //
  // Quick child / subtree duplication / automatic breakdown. All three
  // emit a single undoable change and mint no new stored fields, so old
  // payloads keep loading untouched.

  /// Adds one child step under [parentId]. Returns an error string, or
  /// null on success. [nodeId] is an optional test seam; the UI leaves it
  /// null so ids are timestamped.
  String? createChild(
    String parentId, {
    String? nodeId,
    String title = 'New step',
    DateTime? now,
  }) {
    if (byId(parentId) == null) return 'Parent node not found.';
    final trimmed = title.trim();
    if (trimmed.isEmpty) return 'Please enter a title.';
    final at = now ?? DateTime.now();
    final id = nodeId ?? 'node:${at.microsecondsSinceEpoch}';
    if (byId(id) != null) return 'A node with that id exists.';
    final child = Node(
      id: id,
      title: trimmed,
      parentIds: [parentId],
      createdAt: at,
    );
    return addNode(child);
  }

  /// Deep-copies [sourceId] and its whole descendant closure. External
  /// parents of copied nodes are preserved, so shared DAG children stay
  /// shared. Copies are titled `<title> (copy)` at the root only.
  /// Returns an error string, or null on success (single undo step).
  String? duplicateSubtree(
    String sourceId, {
    String? attachToParentId,
    String? idSuffix,
    DateTime? now,
  }) {
    final source = byId(sourceId);
    if (source == null) return 'Node not found.';
    if (attachToParentId != null) {
      if (byId(attachToParentId) == null) {
        return 'Parent node not found.';
      }
      if (attachToParentId == sourceId ||
          subtreeIds(sourceId, state).contains(attachToParentId)) {
        return 'Cannot attach a copy under its own subtree.';
      }
    }
    final closure = <String>{sourceId, ...subtreeIds(sourceId, state)};
    final at = now ?? DateTime.now();
    final stamp = idSuffix ?? '${at.microsecondsSinceEpoch}';
    final remap = {
      for (final oldId in closure) oldId: '${oldId}_copy_$stamp',
    };
    for (final newId in remap.values) {
      if (byId(newId) != null) return 'A node with that id exists.';
    }
    final copies = <Node>[];
    for (final n in state) {
      if (!closure.contains(n.id)) continue;
      final parents = [
        for (final p in n.parentIds) remap[p] ?? p,
        if (n.id == sourceId && attachToParentId != null) attachToParentId,
      ];
      copies.add(Node(
        id: remap[n.id]!,
        title: n.id == sourceId ? '${n.title} (copy)' : n.title,
        notes: n.notes,
        parentIds: parents,
        status: NodeStatus.open,
        createdAt: at,
        isUnbounded: n.isUnbounded,
        schedule: n.schedule,
        money: n.money?.copyWith(
            status: MoneyStatus.projected, clearActual: true),
        effort: n.effort,
        recurrence: n.recurrence,
        rule: n.rule,
        instanceOfId: n.instanceOfId == null
            ? null
            : (remap[n.instanceOfId] ?? n.instanceOfId),
        overriddenFields: Set.of(n.overriddenFields),
        sourceEventId: null,
        calendarEventId: null,
        feedId: n.feedId,
        classId: n.classId,
        classLabel: n.classLabel,
        assignees: n.assignees,
      ));
    }
    emitChange([...state, ...copies]);
    return null;
  }

  /// Splits [parentId] into [count] ordered step children in one undoable
  /// change: dates spread across the parent window, money split to the
  /// cent, effort split by whole minutes. The automation that keeps the
  /// fast-changing bottom of a big goal tree cheap to rebuild week to
  /// week — steps stay estimates ([isFixed] false) so they move freely.
  ({String? error, List<String> ids}) breakdownGoal(
    String parentId, {
    int count = 4,
    String stepPrefix = 'Step',
    bool splitMoney = true,
    bool splitEffort = true,
    bool spreadDates = true,
    DateTime? now,
  }) {
    final parent = byId(parentId);
    if (parent == null) {
      return (error: 'Node not found.', ids: const []);
    }
    final n = count.clamp(2, 30);
    final at = now ?? DateTime.now();
    final slices = planBreakdown(
      parent: parent,
      count: n,
      now: at,
      stepPrefix: stepPrefix.trim().isEmpty ? 'Step' : stepPrefix.trim(),
      spreadDates: spreadDates,
      splitMoney: splitMoney,
      splitEffort: splitEffort,
    );
    final stamp = at.microsecondsSinceEpoch;
    final kids = <Node>[];
    for (var i = 0; i < slices.length; i++) {
      final s = slices[i];
      kids.add(Node(
        id: '${parentId}_step${i + 1}_$stamp',
        title: s.title,
        parentIds: [parentId],
        createdAt: at,
        schedule: s.due == null ? null : ScheduleFacet(due: s.due),
        money: s.targetAmount == null || parent.money == null
            ? null
            : MoneyFacet(
                targetAmount: s.targetAmount!,
                direction: parent.money!.direction,
                status: MoneyStatus.projected,
              ),
        effort: s.targetMinutes == null
            ? null
            : EffortFacet(targetMinutes: s.targetMinutes!),
      ));
    }
    if (kids.any((k) => byId(k.id) != null)) {
      return (error: 'A node with that id exists.', ids: const []);
    }
    emitChange([...state, ...kids]);
    return (error: null, ids: [for (final k in kids) k.id]);
  }

  /// Deletes [id], its generated instances, and any orphaned subtree.
  /// Surviving children keep their other parents; fully orphaned children
  /// become roots.
  void deleteNode(String id) {
    // Single-pass worklist BFS via a byParent index: O(n) instead of the
    // old fixpoint loop which rescanned state until it stopped growing.
    final byParent = <String, List<String>>{};
    final byInstanceOf = <String, List<String>>{};
    for (final n in state) {
      for (final p in n.parentIds) {
        (byParent[p] ??= []).add(n.id);
      }
      final t = n.instanceOfId;
      if (t != null) (byInstanceOf[t] ??= []).add(n.id);
    }
    final doomed = <String>{id};
    final queue = <String>[id];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      final instances = byInstanceOf[current];
      if (instances != null) {
        for (final child in instances) {
          if (doomed.add(child)) queue.add(child);
        }
      }
      final children = byParent[current];
      if (children == null) continue;
      for (final child in children) {
        if (doomed.contains(child)) continue;
        final node = _byIdMap[child];
        if (node == null) continue;
        // Cascade only when ALL parents are doomed (DAG-aware).
        if (node.parentIds.isNotEmpty &&
            node.parentIds.every(doomed.contains)) {
          if (doomed.add(child)) queue.add(child);
        }
      }
    }
    final next = <Node>[];
    for (final n in state) {
      if (doomed.contains(n.id)) continue;
      final keptParents =
          n.parentIds.where((p) => !doomed.contains(p)).toList();
      next.add(keptParents.length == n.parentIds.length
          ? n
          : n.copyWith(parentIds: keptParents));
    }
    emitChange(next);
  }

  void toggleDone(String id, {DateTime? now}) {
    final node = byId(id);
    if (node == null) return;
    final at = now ?? DateTime.now();
    updateNode(node.isDone
        ? node.copyWith(status: NodeStatus.open, clearCompletedAt: true)
        : node.copyWith(status: NodeStatus.done, completedAt: at));
  }
  void setStatus(String id, NodeStatus status, {DateTime? now}) {
    final node = byId(id);
    if (node == null || node.status == status) return;
    final at = now ?? DateTime.now();
    updateNode(status == NodeStatus.done
        ? node.copyWith(status: status, completedAt: at)
        : node.copyWith(status: status, clearCompletedAt: true));
  }

  /// Sets the calendar/planned work block, preserving the rest of the
  /// schedule (due date, fixed flag). Used by the follow-up scheduler.
  void setScheduleBlock(String id, DateTime start, DateTime end) {
    final node = byId(id);
    if (node == null) return;
    final normalizedEnd =
        end.isAfter(start) ? end : start.add(const Duration(hours: 1));
    final current = node.schedule;
    updateNode(node.copyWith(
      schedule: ScheduleFacet(
        due: current?.due,
        start: start,
        end: normalizedEnd,
        allDay: current?.allDay ?? false,
        isFixed: current?.isFixed ?? false,
      ),
    ));
  }

  void clearScheduleBlock(String id) {
    final node = byId(id);
    final current = node?.schedule;
    if (node == null || current == null || !current.hasCalendarBlock) {
      return;
    }
    updateNode(node.copyWith(
      schedule: current.copyWith(
          clearStart: true, clearEnd: true),
    ));
  }

  /// Points a node at its personal calendar event (node → event side of
  /// the link; the event's `taskId` points back).
  void setCalendarEvent(String nodeId, String eventId) {
    final node = byId(nodeId);
    if (node == null || node.calendarEventId == eventId) return;
    updateNode(node.copyWith(calendarEventId: eventId));
  }

  void clearCalendarEvent(String nodeId) {
    final node = byId(nodeId);
    if (node == null || node.calendarEventId == null) return;
    updateNode(node.copyWith(clearCalendarEvent: true));
  }

  /// Clears personal links pointing at [eventId] (event deleted or
  /// unlinked from the event side).
  void clearCalendarEventForEvent(String eventId) {
    var changed = false;
    final next = [
      for (final n in state)
        if (n.calendarEventId == eventId)
          () {
            changed = true;
            return n.copyWith(clearCalendarEvent: true);
          }()
        else
          n,
    ];
    if (changed) emitChange(next);
  }

  // ── Time tracking (mirrors TaskCubit, single active timer) ──────────

  String? get activeTrackingId {
    for (final n in state) {
      if (n.isTracking) return n.id;
    }
    return null;
  }

  void startTracking(String id, {DateTime? now}) {
    final target = byId(id);
    if (target == null || target.isDone || target.isTracking) return;
    final at = now ?? DateTime.now();
    var next = state;
    final activeId = activeTrackingId;
    if (activeId != null && activeId != id) {
      final active = byId(activeId);
      if (active != null && active.timerStartedAt != null) {
        final s = active.timerStartedAt!;
        final e = at.isAfter(s) ? at : s.add(const Duration(seconds: 1));
        next = next
            .map((n) => n.id == activeId
                ? n.copyWith(
                    actualStart: s, actualEnd: e, clearTimerStartedAt: true)
                : n)
            .toList();
      }
    }
    next = next
        .map((n) => n.id == id ? n.copyWith(timerStartedAt: at) : n)
        .toList();
    if (next != state) emitChange(next);
  }

  void stopTracking(String id, {DateTime? now}) {
    final node = byId(id);
    if (node == null || !node.isTracking) return;
    final at = now ?? DateTime.now();
    final s = node.timerStartedAt!;
    final e = at.isAfter(s) ? at : s.add(const Duration(seconds: 1));
    updateNode(node.copyWith(
        actualStart: s, actualEnd: e, clearTimerStartedAt: true));
  }

  void cancelTracking(String id) {
    final node = byId(id);
    if (node == null || !node.isTracking) return;
    updateNode(node.copyWith(clearTimerStartedAt: true));
  }

  void clearReported(String id) {
    final node = byId(id);
    if (node == null) return;
    if (node.actualStart == null &&
        node.actualEnd == null &&
        !node.isTracking) {
      return;
    }
    updateNode(node.copyWith(
      clearActualStart: true,
      clearActualEnd: true,
      clearTimerStartedAt: true,
    ));
  }

  // ── Money: subdivide / merge / link transaction ─────────────────────

  /// Split [id] into a part of [splitAmount] (keeps the id) plus a
  /// remainder node. Amounts are positive magnitudes.
  void subdivideNode(String id, double splitAmount) {
    final node = byId(id);
    final money = node?.money;
    if (node == null || money == null) return;
    final total = money.effectiveTarget;
    final part = splitAmount.abs().clamp(0.0, total);
    final remainder = total - part;
    if (part <= 0 || remainder <= 0) return;
    final reduced = node.copyWith(
      money: money.copyWith(targetAmount: part),
      overriddenFields: {...node.overriddenFields, 'money.targetAmount'},
    );
    final leftover = Node(
      id: '${id}_rem_${DateTime.now().millisecondsSinceEpoch}',
      title: '${node.title} (remainder)',
      parentIds: node.parentIds,
      createdAt: DateTime.now(),
      schedule: node.schedule,
      money: MoneyFacet(
        targetAmount: remainder,
        direction: money.direction,
        status: money.status,
        period: money.period,
        customPeriodDays: money.customPeriodDays,
        isRecurring: money.isRecurring,
        autoRollover: money.autoRollover,
        isFixed: money.isFixed,
      ),
      effort: node.effort,
      instanceOfId: node.instanceOfId,
    );
    emitChange([
      for (final n in state) n.id == id ? reduced : n,
      leftover,
    ]);
  }

  void mergeNodes(String keepId, String absorbId) {
    final keep = byId(keepId);
    final absorb = byId(absorbId);
    if (keep == null || absorb == null || keepId == absorbId) return;
    final keepMoney = keep.money;
    final absorbMoney = absorb.money;
    if (keepMoney == null || absorbMoney == null) return;
    final merged = keep.copyWith(
      money: keepMoney.copyWith(
        targetAmount:
            keepMoney.effectiveTarget + absorbMoney.effectiveTarget,
        rolloverAmount: 0.0,
      ),
      overriddenFields: {...keep.overriddenFields, 'money.targetAmount'},
    );
    emitChange([
      for (final n in state)
        if (n.id != absorbId) n.id == keepId ? merged : n,
    ]);
  }

  /// Report finances by assigning a transaction, mirroring the
  /// ExpenseCubit reconciliation policy: exact match goes concrete,
  /// smaller subdivides with a remainder, larger logs the actual
  /// (over cap, but the template is untouched).
  void linkTransaction({
    required String nodeId,
    required String transactionId,
    required double transactionAmount,
  }) {
    final node = byId(nodeId);
    if (node == null) return;
    final money = node.money;
    if (money == null) {
      // Ad-hoc link: audit trail only; actuals resolve via txn amounts.
      if (!nodeLinkedTxnIds(node).contains(transactionId)) {
        updateNode(node.copyWith(
            money: MoneyFacet(
          targetAmount: 0,
          actualAmount: transactionAmount.abs(),
          status: MoneyStatus.paid,
          linkedTransactionIds: [
            ...nodeLinkedTxnIds(node),
            transactionId
          ],
        )));
      }
      return;
    }
    final target = money.effectiveTarget;
    final txnAbs = transactionAmount.abs();
    // Linking makes the node concrete: it now owns its money fields and
    // stops inheriting template changes for them.
    Set<String> owned(Node n) => {
          ...n.overriddenFields,
          'money.targetAmount',
          'money.actualAmount',
          'money.status',
        };
    if (target <= 0 || (target - txnAbs).abs() < 0.01) {
      updateNode(node.copyWith(
        money: money.copyWith(
          actualAmount: txnAbs,
          status: MoneyStatus.paid,
          linkedTransactionIds: [
            ...money.linkedTransactionIds,
            transactionId
          ],
        ),
        overriddenFields: owned(node),
      ));
    } else if (txnAbs < target) {
      final reduced = node.copyWith(
        money: money.copyWith(
          targetAmount: txnAbs,
          actualAmount: txnAbs,
          status: MoneyStatus.paid,
          linkedTransactionIds: [
            ...money.linkedTransactionIds,
            transactionId
          ],
        ),
        overriddenFields: owned(node),
      );
      final leftover = Node(
        id: '${nodeId}_rem_${DateTime.now().millisecondsSinceEpoch}',
        title: '${node.title} (remainder)',
        parentIds: node.parentIds,
        createdAt: DateTime.now(),
        schedule: node.schedule,
        money: MoneyFacet(
          targetAmount: target - txnAbs,
          direction: money.direction,
          status: money.status,
          period: money.period,
          customPeriodDays: money.customPeriodDays,
          isRecurring: money.isRecurring,
          autoRollover: money.autoRollover,
          isFixed: money.isFixed,
        ),
        instanceOfId: node.instanceOfId,
      );
      emitChange([
        for (final n in state) n.id == nodeId ? reduced : n,
        leftover,
      ]);
    } else {
      updateNode(node.copyWith(
        money: money.copyWith(
          actualAmount: txnAbs,
          status: MoneyStatus.paid,
          linkedTransactionIds: [
            ...money.linkedTransactionIds,
            transactionId
          ],
        ),
        overriddenFields: owned(node),
      ));
    }
  }

  void unlinkTransaction(String nodeId, String transactionId) {
    final node = byId(nodeId);
    final money = node?.money;
    if (node == null || money == null) return;
    if (!money.linkedTransactionIds.contains(transactionId)) return;
    updateNode(node.copyWith(
        money: money.copyWith(
      linkedTransactionIds: money.linkedTransactionIds
          .where((t) => t != transactionId)
          .toList(),
    )));
  }

  // ── Recurrence: materialize template instances ──────────────────────

  /// Generate dated child instances for template [templateId] across
  /// [from]..[horizon]. Existing instances (user-edited) are never
  /// overwritten. Silent (no undo record): generation is a system action
  /// like feed sync. Returns the number created.
  ///
  /// When [existingIds] is supplied the caller guarantees it already
  /// contains every node id (shared across templates), so this call never
  /// rebuilds the set and never emits — the caller emits once. Used by
  /// [generateInstancesForTemplates] to avoid an O(templates × nodes)
  /// rescan plus an emit storm.
  int generateInstances({
    required String templateId,
    required DateTime from,
    required DateTime horizon,
    Set<String>? existingIds,
  }) {
    final template = byId(templateId);
    final recurrence = template?.recurrence;
    if (template == null || recurrence == null) return 0;
    final anchor =
        template.schedule?.due ?? template.schedule?.start ?? from;
    var cursor = _firstOnOrAfter(anchor, recurrence, from);
    final owned = existingIds != null;
    final known = existingIds ?? state.map((n) => n.id).toSet();
    final fresh = <Node>[];
    var guard = 0;
    final end = recurrence.endDate != null &&
            recurrence.endDate!.isBefore(horizon)
        ? recurrence.endDate!
        : horizon;
    while (!cursor.isAfter(end)) {
      final id = _instanceId(templateId, cursor, recurrence.frequency);
      if (!known.contains(id)) {
        fresh.add(_spawnInstance(template, id, cursor));
        known.add(id);
      }
      cursor = _next(cursor, recurrence);
      if (++guard > 5000) break;
    }
    if (fresh.isNotEmpty && !owned) emitSilent([...state, ...fresh]);
    if (fresh.isNotEmpty && owned) {
      // Caller batches: append directly without emitting; the shared
      // [known] set already tracks the new ids.
      _pendingBatchedInstances.addAll(fresh);
    }
    return fresh.length;
  }

  final List<Node> _pendingBatchedInstances = [];

  /// Batch version of [generateInstances]: one id-set build and one emit
  /// for [templateIds], instead of one scan + one emit per template.
  /// Returns the total number created.
  int generateInstancesForTemplates({
    required Iterable<String> templateIds,
    required DateTime from,
    required DateTime horizon,
  }) {
    _pendingBatchedInstances.clear();
    final known = state.map((n) => n.id).toSet();
    var total = 0;
    for (final id in templateIds) {
      total += generateInstances(
        templateId: id,
        from: from,
        horizon: horizon,
        existingIds: known,
      );
    }
    final fresh = _pendingBatchedInstances.toList();
    _pendingBatchedInstances.clear();
    if (fresh.isNotEmpty) emitSilent([...state, ...fresh]);
    return total;
  }

  Node _spawnInstance(Node template, String id, DateTime date) {
    final block = template.schedule;
    Duration? length;
    if (block?.start != null && block?.end != null) {
      final d = block!.end!.difference(block.start!);
      if (d.inMinutes > 0) length = d;
    }
    final day = DateTime(date.year, date.month, date.day);
    ScheduleFacet? schedule;
    if (block != null) {
      final dueTime = block.due;
      final due = dueTime == null
          ? day
          : DateTime(day.year, day.month, day.day, dueTime.hour,
              dueTime.minute);
      DateTime? start;
      DateTime? end;
      if (length != null) {
        final base = block.start;
        start = base == null
            ? day
            : DateTime(day.year, day.month, day.day, base.hour,
                base.minute);
        end = start.add(length);
      }
      schedule = ScheduleFacet(
        due: due,
        start: start,
        end: end,
        allDay: block.allDay,
        isFixed: block.isFixed,
      );
    } else {
      schedule = ScheduleFacet(due: day);
    }
    MoneyFacet? money = template.money;
    if (money != null) {
      money = MoneyFacet(
        targetAmount: money.targetAmount,
        direction: money.direction,
        status: MoneyStatus.projected,
        period: money.period,
        customPeriodDays: money.customPeriodDays,
        isRecurring: false,
        autoRollover: money.autoRollover,
        rolloverAmount: 0.0,
        isFixed: money.isFixed,
      );
    }
    return Node(
      id: id,
      title: template.title,
      notes: template.notes,
      parentIds: [template.id],
      createdAt: date,
      schedule: schedule,
      money: money,
      effort: template.effort,
      instanceOfId: template.id,
      sourceEventId: template.sourceEventId,
      calendarEventId: template.calendarEventId,
      feedId: template.feedId,
      classId: template.classId,
      classLabel: template.classLabel,
      assignees: template.assignees,
    );
  }

  // ── Legacy importers (one-time adoption, permanent API) ─────────────
  //
  // Each maps one legacy object to a Node without touching the legacy
  // cubits, so old data is never wiped and both systems can coexist
  // while the UI migrates.

  /// Translates legacy [Expense.overriddenFields] keys to node paths.
  ///
  /// [Expense.overrideField] records flat field names ("name", "amount",
  /// "date", "category", "notes") while [Node.overriddenFields] uses
  /// facet-qualified paths ("money.targetAmount", "schedule.due", "title").
  /// Passing the legacy set through verbatim — as this importer used to —
  /// leaves every override inert, because nothing reads a key like
  /// "amount" off a node: the user's edit is preserved but stops
  /// signalling ownership, so the next template change silently overwrites
  /// it.
  ///
  /// Keys with no node equivalent are kept verbatim rather than dropped,
  /// so the fact that the field was overridden survives even though the
  /// node has nowhere to put the value.
  static Set<String> _translateLegacyOverrides(Set<String> legacy) {
    const legacyToNode = {
      'name': 'title',
      'notes': 'notes',
      'amount': 'money.targetAmount',
      'date': 'schedule.due',
      'category': 'category',
    };
    return {
      for (final key in legacy) legacyToNode[key] ?? key,
    };
  }

  String importGoal(Goal goal) {
    final existing = byId('node:${goal.id}');
    if (existing != null) return existing.id;
    final now = DateTime.now();
    ScheduleFacet? schedule;
    if (goal.startDate.millisecondsSinceEpoch != 0 ||
        goal.deadline.millisecondsSinceEpoch != 0) {
      schedule = ScheduleFacet(due: goal.deadline, start: goal.startDate);
    }
    MoneyFacet? money;
    EffortFacet? effort;
    switch (goal.type) {
      case GoalType.financial:
        money = MoneyFacet(
          targetAmount: goal.targetAmount ?? 0,
          direction: MoneyDirection.spend,
          period: goal.period,
          customPeriodDays: goal.customPeriodDays,
          isRecurring: goal.isRecurring,
          autoRollover: goal.autoRollover,
          rolloverAmount: goal.rolloverAmount,
        );
      case GoalType.time:
        effort = goal.targetMinutes == null
            ? null
            : EffortFacet(targetMinutes: goal.targetMinutes!);
      case GoalType.checklist:
        break;
    }
    final node = Node(
      id: 'node:${goal.id}',
      title: goal.title,
      notes: goal.notes,
      parentIds: goal.parentId == null ? const [] : ['node:${goal.parentId}'],
      status: goal.done
          ? NodeStatus.done
          : (goal.failed ? NodeStatus.failed : NodeStatus.open),
      completedAt: goal.completedAt,
      createdAt: now,
      schedule: schedule ??
          (goal.showInTasks ? ScheduleFacet(due: goal.deadline) : null),
      money: money,
      effort: effort,
    );
    emitChange([...state, node]);
    return node.id;
  }

  String importTask(Task task) {
    // Imported homework shadows keep the event id so feed sync finds the
    // same node that shadows used to use (no duplicates after migration).
    final nodeId = task.sourceEventId != null
        ? task.sourceEventId!
        : 'node:${task.id}';
    final existing = byId(nodeId);
    if (existing != null) return existing.id;
    final node = Node(
      id: nodeId,
      title: task.title,
      notes: task.notes,
      createdAt: DateTime.now(),
      status: task.done
          ? NodeStatus.done
          : (task.failed ? NodeStatus.failed : NodeStatus.open),
      completedAt: task.completedAt,
      schedule: (task.due == null &&
              task.plannedStart == null &&
              task.plannedEnd == null)
          ? null
          : ScheduleFacet(
              due: task.due,
              start: task.plannedStart,
              end: task.plannedEnd,
            ),
      sourceEventId: task.sourceEventId,
      calendarEventId: task.calendarEventId,
      classId: task.classId,
      classLabel: task.classLabel,
      actualStart: task.actualStart,
      actualEnd: task.actualEnd,
      timerStartedAt: task.timerStartedAt,
      assignees: task.assignees,
    );
    emitChange([...state, node]);
    return node.id;
  }

  String importBudget(Budget budget) {
    final existing = byId('node:${budget.id}');
    if (existing != null) return existing.id;
    final node = Node(
      id: 'node:${budget.id}',
      title: budget.name,
      notes: 'Imported budget category: ${budget.category}',
      createdAt: DateTime.now(),
      schedule: ScheduleFacet(due: budget.endDate ?? budget.startDate),
      money: MoneyFacet(
        targetAmount: budget.goalAmount,
        direction: MoneyDirection.spend,
        period: budget.period,
        customPeriodDays: budget.customPeriodDays,
        isRecurring: budget.isRecurring,
        autoRollover: budget.autoRollover,
        rolloverAmount: budget.rolloverAmount,
      ),
      recurrence: budget.isRecurring
          ? NodeRecurrence(
              frequency: budget.period,
              customPeriodDays: budget.customPeriodDays,
              endDate: budget.endDate,
            )
          : null,
    );
    emitChange([...state, node]);
    return node.id;
  }

  String importExpense(Expense expense) {
    final existing = byId('node:${expense.id}');
    if (existing != null) return existing.id;
    final node = Node(
      id: 'node:${expense.id}',
      title: expense.name,
      notes: expense.notes,
      parentIds: expense.parentExpenseId == null
          ? const []
          : ['node:${expense.parentExpenseId}'],
      createdAt: DateTime.now(),
      schedule: ScheduleFacet(due: expense.date),
      money: MoneyFacet(
        targetAmount: expense.amount.abs(),
        actualAmount:
            expense.isConcrete ? expense.amount.abs() : null,
        direction:
            expense.amount < 0 ? MoneyDirection.spend : MoneyDirection.income,
        status: switch (expense.status) {
          ExpenseStatus.projected => MoneyStatus.projected,
          ExpenseStatus.due => MoneyStatus.due,
          ExpenseStatus.paid => MoneyStatus.paid,
        },
        linkedTransactionIds: expense.linkedTransactionId == null
            ? const []
            : [expense.linkedTransactionId!],
      ),
      overriddenFields: _translateLegacyOverrides(expense.overriddenFields),
    );
    emitChange([...state, node]);
    return node.id;
  }

  String importRecurringRule(RecurringRule rule) {
    final existing = byId('node:${rule.id}');
    if (existing != null) return existing.id;
    final node = Node(
      id: 'node:${rule.id}',
      title: rule.name,
      createdAt: DateTime.now(),
      schedule: ScheduleFacet(due: rule.startDate),
      money: MoneyFacet(
        targetAmount: rule.amount.abs(),
        direction: rule.amount < 0
            ? MoneyDirection.spend
            : MoneyDirection.income,
        period: rule.frequency,
        customPeriodDays: rule.customPeriodDays,
        isRecurring: true,
      ),
      recurrence: NodeRecurrence(
        frequency: rule.frequency,
        customPeriodDays: rule.customPeriodDays,
        endDate: rule.endDate,
        dayOfMonth: rule.dayOfMonth,
        dayOfWeek: rule.dayOfWeek,
      ),
    );
    emitChange([...state, node]);
    return node.id;
  }

  // ── Calendar event links ──────────────────────────────────────────
  //
  // Backing-node shapes (mirrors the retired TaskCubit contract):
  // - personal events → linked node (`calendarEventId`, id `node:<eventId>`,
  //   event `taskId` points back);
  // - feed events → homework node (`sourceEventId`, id == event id).

  /// All nodes backing an event: personal links ([Node.calendarEventId])
  /// and homework nodes ([Node.sourceEventId]).
  List<Node> nodesForEventId(String eventId) =>
      List<Node>.unmodifiable(_byEventId[eventId] ?? const <Node>[]);

  Node? nodeForCalendarEvent(String eventId) {
    final list = _byEventId[eventId];
    if (list == null) return null;
    for (final n in list) {
      if (n.calendarEventId == eventId) return n;
    }
    return null;
  }

  /// Creates or refreshes the personal linked node for [event] so the
  /// event shows up in the queue. Returns the node id. Title/notes/due/
  /// done mirror the event; completion is kept in sync both ways.
  String upsertLinkedNodeForEvent(PlannerEvent event) {
    Node syncLinked(Node linked) {
      final hasNotes = (event.notes ?? '').trim().isNotEmpty;
      // Imported homework keeps the due date its feed gave it: the block
      // says when the user plans to work, which is not when the
      // assignment is due. Personal nodes have no such date, so their
      // due stays the event's own start (the previous behaviour).
      final due = linked.sourceEventId != null
          ? (linked.schedule?.due ?? event.start)
          : event.start;
      return linked.copyWith(
        title: event.subject,
        notes: hasNotes ? event.notes!.trim() : null,
        clearNotes: !hasNotes,
        schedule: ScheduleFacet(
          due: due,
          start: event.start,
          end: event.end,
        ),
        status: event.done ? NodeStatus.done : NodeStatus.open,
        completedAt: event.completedAt,
        clearCompletedAt: !event.done || event.completedAt == null,
        assignees: event.assignees,
      );
    }

    if (event.taskId != null) {
      final linked = byId(event.taskId!);
      if (linked != null) {
        updateNode(syncLinked(linked));
        return linked.id;
      }
    }
    final byCalendar = nodeForCalendarEvent(event.id);
    if (byCalendar != null) {
      updateNode(syncLinked(byCalendar));
      return byCalendar.id;
    }
    final id = 'node:${event.id}';
    addNode(Node(
      id: id,
      title: event.subject,
      notes: event.notes,
      createdAt: DateTime.now(),
      status: event.done ? NodeStatus.done : NodeStatus.open,
      completedAt: event.completedAt,
      schedule: ScheduleFacet(
        due: event.start,
        start: event.start,
        end: event.end,
      ),
      classLabel: event.classLabel,
      calendarEventId: event.id,
      assignees: event.assignees,
    ));
    return id;
  }

  /// Backing-node check matching [_byEventId]: personal links plus feed
  /// shadows. Used by the batched mirrors below so they can fold a whole
  /// event's nodes into one emit instead of one emit per node.
  static bool _backsEvent(Node node, String eventId) =>
      node.calendarEventId == eventId || node.sourceEventId == eventId;

  /// Mirrors an event's completion onto every backing node in ONE emit
  /// (one undo record, one rebuild) instead of one emit per node.
  void setDoneForEvent(
    String eventId, {
    required bool done,
    DateTime? completedAt,
  }) {
    var changed = false;
    final next = <Node>[];
    for (final node in state) {
      if (!_backsEvent(node, eventId) ||
          (node.isDone == done &&
              (done || node.completedAt == null) &&
              (node.completedAt == completedAt ||
                  (!done && completedAt == null)))) {
        next.add(node);
        continue;
      }
      changed = true;
      next.add(
        node.copyWith(
          status: done ? NodeStatus.done : NodeStatus.open,
          completedAt: completedAt,
          clearCompletedAt: !done,
        ),
      );
    }
    if (changed) emitChange(next);
  }

  /// Mirrors an event's failed flag onto backing nodes in ONE emit.
  /// Clearing (`failed: false`) only re-opens nodes that are actually
  /// failed — done nodes keep their completion. (Previously every non-open
  /// node was flipped to open, so completing a mirrored task immediately
  /// undid the just-applied completion.)
  void setFailedForEvent(String eventId, bool failed) {
    var changed = false;
    final next = <Node>[];
    for (final node in state) {
      if (!_backsEvent(node, eventId)) {
        next.add(node);
        continue;
      }
      if (failed) {
        if (node.status == NodeStatus.failed) {
          next.add(node);
          continue;
        }
        changed = true;
        next.add(node.copyWith(
          status: NodeStatus.failed,
          clearCompletedAt: true,
        ));
      } else {
        if (node.status != NodeStatus.failed) {
          next.add(node);
          continue;
        }
        changed = true;
        next.add(node.copyWith(
          status: NodeStatus.open,
          clearCompletedAt: true,
        ));
      }
    }
    if (changed) emitChange(next);
  }

  /// Ensures a homework-style node exists for a feed event that was
  /// manually marked as actionable (e.g. a class session the user
  /// promotes, or a feed with "create tasks" off). Mirrors completion.
  void ensureNodeForFeedEvent(PlannerEvent event) {
    if (event.feedId == null) return;
    final existing = nodesForEventId(event.id);
    if (existing.isNotEmpty) {
      final want = event.failed
          ? NodeStatus.failed
          : (event.done ? NodeStatus.done : NodeStatus.open);
      for (final node in existing) {
        if (node.status != want ||
            node.completedAt != event.completedAt ||
            !_sameAssignees(node.assignees, event.assignees)) {
          updateNode(
            node.copyWith(
              status: want,
              completedAt: event.completedAt,
              clearCompletedAt: !event.done,
              assignees: event.assignees,
            ),
          );
        }
      }
      return;
    }
    addNode(Node(
      id: event.id,
      title: event.subject,
      notes: event.notes,
      createdAt: DateTime.now(),
      status: event.done ? NodeStatus.done : NodeStatus.open,
      completedAt: event.completedAt,
      schedule: ScheduleFacet(
        due: event.start,
        start: event.start,
        end: event.end,
      ),
      sourceEventId: event.id,
      feedId: event.feedId,
      classId: event.feedId,
      classLabel: event.classLabel,
      assignees: event.assignees,
    ));
  }

  /// Deletes every node backing [eventId] (personal link and/or homework
  /// node). Used when an event is deleted or un-marked as actionable.
  /// Silent (plain emit, no undo record of its own): callers deleting
  /// events fold the removal into their own undo step via
  /// [RevertableHydratedCubit.atomic], so undo restores both sides.
  void removeNodesForEvent(String eventId) {
    final ids = nodesForEventId(eventId).map((n) => n.id).toSet();
    if (ids.isEmpty) return;
    emitSilent(state.where((n) => !ids.contains(n.id)).toList());
  }

  // ── Feed import ─────────────────────────────────────────────────────

  /// Creates homework nodes for feed [events] (silent, like a sync).
  /// Completion survives re-syncs because existing source links are
  /// skipped. Learning Suite schedule/commentary clutter is dropped on
  /// resync while done nodes are kept as completion history.
  void importFromFeed(
    List<PlannerEvent> events,
    Feed feed, {
    Set<String> taskOptOutIds = const {},
  }) {
    final now = DateTime.now();
    var base = state;
    if (feed.kind == FeedKind.learningSuite) {
      base = base
          .where(
            (n) =>
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
    final imported = <Node>[];
    for (final event in events) {
      if (taskOptOutIds.contains(event.id)) continue;
      if (!isNodeCandidate(event, feed, now)) continue;
      if (existingSource.contains(event.id)) continue;
      if (existing.contains(event.id)) continue;
      // Learning Suite open..due windows (DTSTART..DTEND) are due at the
      // end of the window: without this every window node would be due
      // (and instantly overdue) on its open date.
      final isWindow = feed.kind == FeedKind.learningSuite &&
          event.allDay &&
          event.end.difference(event.start) > const Duration(days: 1);
      imported.add(Node(
        id: event.id,
        title: event.subject,
        notes: event.notes,
        createdAt: DateTime.now(),
        status: event.done ? NodeStatus.done : NodeStatus.open,
        completedAt: event.completedAt,
        schedule: ScheduleFacet(
          due: isWindow ? event.end : event.start,
          start: event.start,
          end: event.end,
        ),
        sourceEventId: event.id,
        feedId: feed.id,
        classId: feed.id,
        classLabel: event.classLabel,
        assignees: event.assignees,
      ));
    }
    final next = [...base, ...imported];
    if (imported.isNotEmpty || next.length != state.length) {
      emitSilent(next);
    }
  }

  /// Deletes every homework node imported from [feedId]. Silent: feed
  /// removal records the composite undo itself.
  void removeImportedNodesFor(String feedId) {
    emitSilent(
      state
          .where((n) => !(n.classId == feedId && n.sourceEventId != null))
          .toList(),
    );
  }

  /// Nodes from [feedId] that remain visible under feed visibility rules.
  List<Node> visibleNodes(List<Node> nodes, Set<String> enabledFeedIds) =>
      nodes.where((n) {
        if (n.sourceEventId == null) return true;
        return enabledFeedIds.contains(n.classId);
      }).toList();

  // ── Budget rollover (ported from BudgetCubit) ───────────────────────

  /// Manually roll surplus/deficit into the next period. [spentAmount] is
  /// the total spent in the current period (positive magnitude).
  void applyRollover(String nodeId, double spentAmount) {
    final node = byId(nodeId);
    final money = node?.money;
    if (node == null || money == null || !money.isRecurring) return;
    final surplus = money.targetAmount - spentAmount;
    updateNode(node.copyWith(
      money: money.copyWith(rolloverAmount: money.rolloverAmount + surplus),
    ));
  }

  // ── Persistence (per-item tolerant) ─────────────────────────────────

  @override
  List<Node>? fromJson(Map<String, dynamic> json) {
    final list = json['nodes'] as List<dynamic>?;
    if (list == null) return null;
    final out = <Node>[];
    for (final item in list) {
      if (item is! Map) continue;
      try {
        out.add(Node.fromJson(Map<String, dynamic>.from(item)));
      } catch (_) {}
    }
    return out;
  }

  @override
  Map<String, dynamic> toJson(List<Node> state) =>
      {'nodes': state.map((n) => n.toJson()).toList()};
}

List<String> nodeLinkedTxnIds(Node node) =>
    node.money?.linkedTransactionIds ?? const [];

bool _sameAssignees(List<dynamic> a, List<dynamic> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

DateTime _firstOnOrAfter(
    DateTime anchor, NodeRecurrence recurrence, DateTime from) {
  if (!anchor.isBefore(from)) return _snap(anchor, recurrence);
  // Fast-forward monthly-ish recurrences without day-by-day iteration.
  var cursor = _snap(from, recurrence);
  var guard = 0;
  while (cursor.isBefore(from)) {
    cursor = _next(cursor, recurrence);
    if (++guard > 5000) break;
  }
  return cursor;
}

DateTime _snap(DateTime date, NodeRecurrence recurrence) {
  switch (recurrence.frequency) {
    case TimeScale.monthly:
      final day =
          (recurrence.dayOfMonth ?? date.day).clamp(1, 28);
      var candidate = DateTime(date.year, date.month, day);
      if (candidate.isBefore(DateTime(date.year, date.month, date.day))) {
        candidate = DateTime(date.year, date.month + 1, day);
      }
      return candidate;
    case TimeScale.weekly:
    case TimeScale.biweekly:
      final target = recurrence.dayOfWeek ?? date.weekday;
      var diff = target - date.weekday;
      if (diff < 0) diff += 7;
      final day = DateTime(date.year, date.month, date.day);
      return day.add(Duration(days: diff));
    case TimeScale.daily:
    case TimeScale.quarterly:
    case TimeScale.yearly:
    case TimeScale.custom:
      return DateTime(date.year, date.month, date.day);
  }
}

DateTime _next(DateTime current, NodeRecurrence recurrence) {
  switch (recurrence.frequency) {
    case TimeScale.daily:
      return current.add(const Duration(days: 1));
    case TimeScale.weekly:
      return current.add(const Duration(days: 7));
    case TimeScale.biweekly:
      return current.add(const Duration(days: 14));
    case TimeScale.monthly:
      final day = (recurrence.dayOfMonth ?? current.day).clamp(1, 28);
      return DateTime(current.year, current.month + 1, day);
    case TimeScale.quarterly:
      return DateTime(current.year, current.month + 3, current.day);
    case TimeScale.yearly:
      return DateTime(current.year + 1, current.month, current.day);
    case TimeScale.custom:
      return current.add(Duration(days: recurrence.customPeriodDays ?? 30));
  }
}

String _instanceId(String templateId, DateTime date, TimeScale frequency) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  if (frequency == TimeScale.monthly ||
      frequency == TimeScale.quarterly ||
      frequency == TimeScale.yearly) {
    return '$templateId@$y-$m';
  }
  final d = date.day.toString().padLeft(2, '0');
  return '$templateId@$y-$m-$d';
}
