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
import '../service/node_feed.dart';
import '../service/node_progress.dart';

/// Unified goals/tasks store. One DAG of [Node]s replaces Goal + Task +
/// Budget + Expense; transactions and calendar events stay separate and
/// link in directly (no tags anywhere).
class NodeCubit extends RevertableHydratedCubit<List<Node>> {
  NodeCubit() : super(const []);

  // ── Lookups ─────────────────────────────────────────────────────────

  Node? byId(String id) {
    for (final n in state) {
      if (n.id == id) return n;
    }
    return null;
  }

  List<Node> childrenOf(String parentId) =>
      state.where((n) => n.parentIds.contains(parentId)).toList();

  List<Node> get roots =>
      state.where((n) => n.parentIds.isEmpty).toList();

  List<Node> instancesOf(String templateId) =>
      state.where((n) => n.instanceOfId == templateId).toList();

  /// Emit without an undo record. For system writes (feed sync, instance
  /// generation) that must not pollute the user's undo history.
  void emitSilent(List<Node> next) => emit(next);

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
  /// carry the dates.
  List<Node> get openNodes {
    final open = state
        .where((n) => n.isOpen && !n.isTemplate)
        .toList()
      ..sort(_byDueThenCreated);
    final done = state.where((n) => n.isDone).toList()
      ..sort((a, b) => (b.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(a.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0)));
    return [...open, ...done];
  }

  List<Node> get overdueAndToday {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    return state.where((n) {
      if (!n.isOpen || n.isTemplate) return false;
      final due = n.schedule?.due;
      if (due == null) return false;
      final day = DateTime(due.year, due.month, due.day);
      return day.isBefore(tomorrow);
    }).toList()
      ..sort(_byDueThenCreated);
  }

  /// Open nodes due in the next 7 days (start of today through the end of
  /// the 7th day out). Used by the Home dashboard's week section.
  List<Node> get dueThisWeek {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final endExclusive = today.add(const Duration(days: 8));
    return state.where((n) {
      if (!n.isOpen || n.isTemplate) return false;
      final due = n.schedule?.due;
      if (due == null) return false;
      return !due.isBefore(today) && due.isBefore(endExclusive);
    }).toList()
      ..sort(_byDueThenCreated);
  }

  // ── Validation (DAG) ────────────────────────────────────────────────

  /// Returns an error string, or null when [parentIds] is acceptable.
  String? validateParents(Node draft, List<String> parentIds) {
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
    return null;
  }

  // ── CRUD ────────────────────────────────────────────────────────────

  String? addNode(Node node) {
    if (byId(node.id) != null) return 'A node with that id exists.';
    final error = validateParents(node, node.parentIds);
    if (error != null) return error;
    emitChange([...state, node]);
    return null;
  }

  String? updateNode(Node updated) {
    if (byId(updated.id) == null) return 'Node not found.';
    final error = validateParents(updated, updated.parentIds);
    if (error != null) return error;
    emitChange(
        state.map((n) => n.id == updated.id ? updated : n).toList());
    return null;
  }

  String? reparent(String id, List<String> parentIds) {
    final node = byId(id);
    if (node == null) return 'Node not found.';
    return updateNode(node.copyWith(parentIds: parentIds));
  }

  /// Deletes [id], its generated instances, and any orphaned subtree.
  /// Surviving children keep their other parents; fully orphaned children
  /// become roots.
  void deleteNode(String id) {
    final doomed = <String>{id};
    var grew = true;
    while (grew) {
      grew = false;
      for (final n in state) {
        if (doomed.contains(n.id)) continue;
        if (n.instanceOfId != null && doomed.contains(n.instanceOfId)) {
          if (doomed.add(n.id)) grew = true;
          continue;
        }
        // Cascade only when ALL parents are doomed (DAG-aware).
        if (n.parentIds.isNotEmpty &&
            n.parentIds.every(doomed.contains)) {
          if (doomed.add(n.id)) grew = true;
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
  int generateInstances({
    required String templateId,
    required DateTime from,
    required DateTime horizon,
  }) {
    final template = byId(templateId);
    final recurrence = template?.recurrence;
    if (template == null || recurrence == null) return 0;
    final anchor =
        template.schedule?.due ?? template.schedule?.start ?? from;
    var cursor = _firstOnOrAfter(anchor, recurrence, from);
    final existingIds = state.map((n) => n.id).toSet();
    final fresh = <Node>[];
    var guard = 0;
    final end = recurrence.endDate != null &&
            recurrence.endDate!.isBefore(horizon)
        ? recurrence.endDate!
        : horizon;
    while (!cursor.isAfter(end)) {
      final id = _instanceId(templateId, cursor, recurrence.frequency);
      if (!existingIds.contains(id)) {
        fresh.add(_spawnInstance(template, id, cursor));
        existingIds.add(id);
      }
      cursor = _next(cursor, recurrence);
      if (++guard > 5000) break;
    }
    if (fresh.isNotEmpty) emitSilent([...state, ...fresh]);
    return fresh.length;
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
      overriddenFields: expense.overriddenFields,
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
  List<Node> nodesForEventId(String eventId) => state
      .where((n) =>
          n.calendarEventId == eventId || n.sourceEventId == eventId)
      .toList();

  Node? nodeForCalendarEvent(String eventId) {
    for (final n in state) {
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
      return linked.copyWith(
        title: event.subject,
        notes: hasNotes ? event.notes!.trim() : null,
        clearNotes: !hasNotes,
        schedule: ScheduleFacet(
          due: event.start,
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

  /// Mirrors an event's completion onto every backing node.
  void setDoneForEvent(
    String eventId, {
    required bool done,
    DateTime? completedAt,
  }) {
    for (final node in nodesForEventId(eventId)) {
      if (node.isDone == done &&
          (done || node.completedAt == null) &&
          (node.completedAt == completedAt ||
              (!done && completedAt == null))) {
        continue;
      }
      updateNode(
        node.copyWith(
          status: done ? NodeStatus.done : NodeStatus.open,
          completedAt: completedAt,
          clearCompletedAt: !done,
        ),
      );
    }
  }

  void setFailedForEvent(String eventId, bool failed) {
    for (final node in nodesForEventId(eventId)) {
      final next = failed ? NodeStatus.failed : NodeStatus.open;
      if (node.status == next) continue;
      updateNode(node.copyWith(
        status: next,
        clearCompletedAt: true,
      ));
    }
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
  /// Silent: callers deleting events already record their own undo.
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
