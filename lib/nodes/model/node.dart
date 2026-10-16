import 'package:equatable/equatable.dart';

import 'package:a_fish_in_sea/common/time/planned_actual.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/planner/model/task_assignee.dart';

/// Lifecycle of a node. Replaces the `done`/`failed` bool pairs on
/// [Goal] and [Task] with a single value. Unknown stored values fall back
/// to [open] so renames never wipe state.
enum NodeStatus { open, done, failed, skipped }

/// Meaning of a [MoneyFacet]. Amounts are always positive magnitudes;
/// the direction gives the sign for cash-flow simulation.
enum MoneyDirection { spend, income, save }

/// Projection lifecycle. Mirrors [ExpenseStatus]: estimates start as
/// [projected], become [due] as their date approaches, and turn [paid]
/// once linked to a real transaction (concrete, severed from the template).
enum MoneyStatus { projected, due, paid }

/// Derived-goal evaluation. [none] is a plain node; the others are
/// computed from a query over sibling nodes instead of stored children.
enum NodeRuleKind { none, homeworkAhead, minBalance }

/// When work is due / calendared. All fields optional: a null facet means
/// an undated node. The UI shows a single date; [isFixed] records whether
/// that date is a commitment (solid) or an estimate (faded, free to move).
class ScheduleFacet extends Equatable {
  /// Deadline for the priority queue. Null = not queued.
  final DateTime? due;

  /// Calendar block (doubles as the planned work interval). Null = not
  /// on the calendar.
  final DateTime? start;
  final DateTime? end;
  final bool allDay;

  /// True = commitment. False (default) = estimate, safe to auto-adjust.
  final bool isFixed;

  const ScheduleFacet({
    this.due,
    this.start,
    this.end,
    this.allDay = false,
    this.isFixed = false,
  });

  bool get hasDue => due != null;
  bool get hasCalendarBlock => start != null && end != null;

  Duration? get plannedDuration {
    final s = start;
    final e = end;
    if (s == null || e == null || !e.isAfter(s)) return null;
    return e.difference(s);
  }

  /// The planned half of planned-vs-actual. A [ScheduleFacet] carries no
  /// occurrence of its own — actuals live on [Node] and on
  /// [PlannerEvent] — so this is the claim the facet makes, for callers
  /// that want the comparison without knowing which record they hold.
  PlannedActual get planned =>
      PlannedActual(plannedStart: start, plannedEnd: end);

  ScheduleFacet copyWith({
    DateTime? due,
    bool clearDue = false,
    DateTime? start,
    bool clearStart = false,
    DateTime? end,
    bool clearEnd = false,
    bool? allDay,
    bool? isFixed,
  }) =>
      ScheduleFacet(
        due: clearDue ? null : (due ?? this.due),
        start: clearStart ? null : (start ?? this.start),
        end: clearEnd ? null : (end ?? this.end),
        allDay: allDay ?? this.allDay,
        isFixed: isFixed ?? this.isFixed,
      );

  factory ScheduleFacet.fromJson(Map<String, dynamic> json) => ScheduleFacet(
        due: _tryDate(json['due']),
        start: _tryDate(json['start']),
        end: _tryDate(json['end']),
        allDay: json['allDay'] as bool? ?? false,
        isFixed: json['isFixed'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'due': due?.toIso8601String(),
        'start': start?.toIso8601String(),
        'end': end?.toIso8601String(),
        'allDay': allDay,
        'isFixed': isFixed,
      };

  @override
  List<Object?> get props => [due, start, end, allDay, isFixed];
}

/// Financial facet. This IS the budget/expense: there is no separate
/// expense table for nodes. [targetAmount] is the single UI number;
/// [isFixed] says whether it is a commitment (contract, locked budget)
/// or an estimate that may drift. [linkedTransactionIds] is the audit
/// trail — assigning a transaction is what reports financial progress.
class MoneyFacet extends Equatable {
  final double targetAmount;
  final double? actualAmount;
  final MoneyDirection direction;
  final MoneyStatus status;
  final TimeScale? period;
  final int? customPeriodDays;
  final bool isRecurring;
  final bool autoRollover;
  final double rolloverAmount;
  final bool isFixed;
  final List<String> linkedTransactionIds;

  const MoneyFacet({
    required this.targetAmount,
    this.actualAmount,
    this.direction = MoneyDirection.spend,
    this.status = MoneyStatus.projected,
    this.period,
    this.customPeriodDays,
    this.isRecurring = false,
    this.autoRollover = false,
    this.rolloverAmount = 0.0,
    this.isFixed = false,
    this.linkedTransactionIds = const [],
  });

  double get effectiveTarget => targetAmount + rolloverAmount;
  bool get isConcrete => status == MoneyStatus.paid;

  /// Signed cash-flow magnitude: spend/save leave, income arrives.
  double signedPlanned() {
    final mag = effectiveTarget;
    return direction == MoneyDirection.income ? mag : -mag;
  }

  double? signedActual() {
    final a = actualAmount;
    if (a == null) return null;
    return direction == MoneyDirection.income ? a : -a;
  }

  MoneyFacet copyWith({
    double? targetAmount,
    double? actualAmount,
    bool clearActual = false,
    MoneyDirection? direction,
    MoneyStatus? status,
    TimeScale? period,
    bool clearPeriod = false,
    int? customPeriodDays,
    bool clearCustomPeriod = false,
    bool? isRecurring,
    bool? autoRollover,
    double? rolloverAmount,
    bool? isFixed,
    List<String>? linkedTransactionIds,
  }) =>
      MoneyFacet(
        targetAmount: targetAmount ?? this.targetAmount,
        actualAmount:
            clearActual ? null : (actualAmount ?? this.actualAmount),
        direction: direction ?? this.direction,
        status: status ?? this.status,
        period: clearPeriod ? null : (period ?? this.period),
        customPeriodDays: clearCustomPeriod
            ? null
            : (customPeriodDays ?? this.customPeriodDays),
        isRecurring: isRecurring ?? this.isRecurring,
        autoRollover: autoRollover ?? this.autoRollover,
        rolloverAmount: rolloverAmount ?? this.rolloverAmount,
        isFixed: isFixed ?? this.isFixed,
        linkedTransactionIds:
            linkedTransactionIds ?? this.linkedTransactionIds,
      );

  factory MoneyFacet.fromJson(Map<String, dynamic> json) => MoneyFacet(
        targetAmount: (json['targetAmount'] as num?)?.toDouble() ?? 0.0,
        actualAmount: (json['actualAmount'] as num?)?.toDouble(),
        direction: MoneyDirection.values.firstWhere(
          (e) => e.name == json['direction'],
          orElse: () => MoneyDirection.spend,
        ),
        status: MoneyStatus.values.firstWhere(
          (e) => e.name == json['status'],
          orElse: () => MoneyStatus.projected,
        ),
        period: json['period'] == null
            ? null
            : TimeScale.values.firstWhere(
                (e) => e.name == json['period'],
                orElse: () => TimeScale.monthly,
              ),
        customPeriodDays: (json['customPeriodDays'] as num?)?.toInt(),
        isRecurring: json['isRecurring'] as bool? ?? false,
        autoRollover: json['autoRollover'] as bool? ?? false,
        rolloverAmount: (json['rolloverAmount'] as num?)?.toDouble() ?? 0.0,
        isFixed: json['isFixed'] as bool? ?? false,
        linkedTransactionIds: _stringList(json['linkedTransactionIds']),
      );

  Map<String, dynamic> toJson() => {
        'targetAmount': targetAmount,
        'actualAmount': actualAmount,
        'direction': direction.name,
        'status': status.name,
        'period': period?.name,
        'customPeriodDays': customPeriodDays,
        'isRecurring': isRecurring,
        'autoRollover': autoRollover,
        'rolloverAmount': rolloverAmount,
        'isFixed': isFixed,
        'linkedTransactionIds': linkedTransactionIds,
      };

  @override
  List<Object?> get props => [
        targetAmount,
        actualAmount,
        direction,
        status,
        period,
        customPeriodDays,
        isRecurring,
        autoRollover,
        rolloverAmount,
        isFixed,
        linkedTransactionIds,
      ];
}

/// Time-target facet. Replaces `GoalType.time` + `targetMinutes`.
class EffortFacet extends Equatable {
  final int targetMinutes;
  final bool isFixed;

  const EffortFacet({required this.targetMinutes, this.isFixed = false});

  EffortFacet copyWith({int? targetMinutes, bool? isFixed}) => EffortFacet(
        targetMinutes: targetMinutes ?? this.targetMinutes,
        isFixed: isFixed ?? this.isFixed,
      );

  factory EffortFacet.fromJson(Map<String, dynamic> json) => EffortFacet(
        targetMinutes: (json['targetMinutes'] as num?)?.toInt() ?? 0,
        isFixed: json['isFixed'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() =>
      {'targetMinutes': targetMinutes, 'isFixed': isFixed};

  @override
  List<Object?> get props => [targetMinutes, isFixed];
}

/// Memorization facet (Anki integration, issue #29). A node with this
/// facet is a "review N cards per period" goal whose progress comes from
/// Anki review statistics.
///
/// The numbers are a client-side cache, never credentials: [reviewsActual]
/// is the last synced/manual count for the current period and
/// [lastSyncedAt] says when it was recorded. Sync overwrites the cache —
/// the server only ever sees these plain counts. [deckName] scopes the
/// count to one Anki deck; null counts every deck.
class AnkiFacet extends Equatable {
  final String? deckName;
  final int targetReviews;
  final TimeScale? period;
  final int? customPeriodDays;
  final int? reviewsActual;
  final DateTime? lastSyncedAt;
  final bool isFixed;

  const AnkiFacet({
    this.deckName,
    this.targetReviews = 0,
    this.period,
    this.customPeriodDays,
    this.reviewsActual,
    this.lastSyncedAt,
    this.isFixed = false,
  });

  AnkiFacet copyWith({
    String? deckName,
    bool clearDeck = false,
    int? targetReviews,
    TimeScale? period,
    bool clearPeriod = false,
    int? customPeriodDays,
    bool clearCustomPeriod = false,
    int? reviewsActual,
    bool clearReviewsActual = false,
    DateTime? lastSyncedAt,
    bool clearLastSyncedAt = false,
    bool? isFixed,
  }) =>
      AnkiFacet(
        deckName: clearDeck ? null : (deckName ?? this.deckName),
        targetReviews: targetReviews ?? this.targetReviews,
        period: clearPeriod ? null : (period ?? this.period),
        customPeriodDays: clearCustomPeriod
            ? null
            : (customPeriodDays ?? this.customPeriodDays),
        reviewsActual: clearReviewsActual
            ? null
            : (reviewsActual ?? this.reviewsActual),
        lastSyncedAt: clearLastSyncedAt
            ? null
            : (lastSyncedAt ?? this.lastSyncedAt),
        isFixed: isFixed ?? this.isFixed,
      );

  factory AnkiFacet.fromJson(Map<String, dynamic> json) {
    final rawDeck = json['deckName'] as String?;
    return AnkiFacet(
      deckName: rawDeck == null || rawDeck.trim().isEmpty ? null : rawDeck,
      targetReviews:
          ((json['targetReviews'] as num?)?.toInt() ?? 0).clamp(0, 1000000000),
      period: json['period'] == null
          ? null
          : TimeScale.values.firstWhere(
              (e) => e.name == json['period'],
              orElse: () => TimeScale.monthly,
            ),
      customPeriodDays: (json['customPeriodDays'] as num?)?.toInt(),
      reviewsActual: json['reviewsActual'] == null
          ? null
          : ((json['reviewsActual'] as num?)?.toInt() ?? 0)
              .clamp(0, 1000000000),
      lastSyncedAt: _tryDate(json['lastSyncedAt']),
      isFixed: json['isFixed'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'deckName': deckName,
        'targetReviews': targetReviews,
        'period': period?.name,
        'customPeriodDays': customPeriodDays,
        'reviewsActual': reviewsActual,
        'lastSyncedAt': lastSyncedAt?.toIso8601String(),
        'isFixed': isFixed,
      };

  @override
  List<Object?> get props => [
        deckName,
        targetReviews,
        period,
        customPeriodDays,
        reviewsActual,
        lastSyncedAt,
        isFixed,
      ];
}

/// Recurrence for habit/budget templates. Only set on templates;
/// instances carry concrete dates + `instanceOfId`.
class NodeRecurrence extends Equatable {
  final TimeScale frequency;
  final int? customPeriodDays;
  final DateTime? endDate;
  final int? dayOfMonth;
  final int? dayOfWeek;

  const NodeRecurrence({
    required this.frequency,
    this.customPeriodDays,
    this.endDate,
    this.dayOfMonth,
    this.dayOfWeek,
  });

  NodeRecurrence copyWith({
    TimeScale? frequency,
    int? customPeriodDays,
    DateTime? endDate,
    bool clearEndDate = false,
    int? dayOfMonth,
    int? dayOfWeek,
  }) =>
      NodeRecurrence(
        frequency: frequency ?? this.frequency,
        customPeriodDays: customPeriodDays ?? this.customPeriodDays,
        endDate: clearEndDate ? null : (endDate ?? this.endDate),
        dayOfMonth: dayOfMonth ?? this.dayOfMonth,
        dayOfWeek: dayOfWeek ?? this.dayOfWeek,
      );

  factory NodeRecurrence.fromJson(Map<String, dynamic> json) =>
      NodeRecurrence(
        frequency: TimeScale.values.firstWhere(
          (e) => e.name == json['frequency'],
          orElse: () => TimeScale.daily,
        ),
        customPeriodDays: (json['customPeriodDays'] as num?)?.toInt(),
        endDate: _tryDate(json['endDate']),
        dayOfMonth: (json['dayOfMonth'] as num?)?.toInt(),
        dayOfWeek: (json['dayOfWeek'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'frequency': frequency.name,
        'customPeriodDays': customPeriodDays,
        'endDate': endDate?.toIso8601String(),
        'dayOfMonth': dayOfMonth,
        'dayOfWeek': dayOfWeek,
      };

  @override
  List<Object?> get props =>
      [frequency, customPeriodDays, endDate, dayOfMonth, dayOfWeek];
}

/// Derived-goal definition. Evaluated by query at read time — no stored
/// children to keep in sync on import.
class RuleFacet extends Equatable {
  final NodeRuleKind kind;

  /// For [NodeRuleKind.homeworkAhead]: how many days out must be done.
  final int horizonDays;

  /// For [NodeRuleKind.minBalance]: the floor that must never break.
  final double minBalance;

  const RuleFacet({
    this.kind = NodeRuleKind.none,
    this.horizonDays = 3,
    this.minBalance = 0.0,
  });

  RuleFacet copyWith({
    NodeRuleKind? kind,
    int? horizonDays,
    double? minBalance,
  }) =>
      RuleFacet(
        kind: kind ?? this.kind,
        horizonDays: horizonDays ?? this.horizonDays,
        minBalance: minBalance ?? this.minBalance,
      );

  factory RuleFacet.fromJson(Map<String, dynamic> json) => RuleFacet(
        kind: NodeRuleKind.values.firstWhere(
          (e) => e.name == json['kind'],
          orElse: () => NodeRuleKind.none,
        ),
        horizonDays: (json['horizonDays'] as num?)?.toInt() ?? 3,
        minBalance: (json['minBalance'] as num?)?.toDouble() ?? 0.0,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'horizonDays': horizonDays,
        'minBalance': minBalance,
      };

  @override
  List<Object?> get props => [kind, horizonDays, minBalance];
}

/// Unified goal/task node.
///
/// A node with no facets is an undated, unestimated placeholder — valid by
/// design so planning stays cheap. Facets opt into views:
/// - [schedule] with [ScheduleFacet.due] → priority queue
/// - [schedule] with a start/end block → calendar
/// - [money] → ledger / waterfall
/// - [effort] → time target with planned-vs-actual calibration
/// - [anki] → memorization target fed by Anki review statistics
/// - [recurrence] → habit/budget template generating dated instances
/// - [rule] → derived goal evaluated by query (no tag matching)
///
/// Hierarchy is a DAG via [parentIds]: a node may contribute to several
/// parents (e.g. groceries under both "Food budget" and "Errands").
/// Reporting is direct — subtree sums plus [MoneyFacet.linkedTransactionIds]
/// and recorded actuals. There are no tags.
///
/// An [isUnbounded] node is an abstract, ongoing direction ("serve
/// others"): no due date, no targets, no progress bar. It never completes
/// itself; concrete subgoals underneath carry the dates and the progress.
/// Unbounded nodes stay out of the priority queue, the leaf list, and
/// parent progress averages, so an aspiration that never ends cannot pin a
/// concrete goal below 100%.
///
/// This class carries no `tagIds`. The legacy models it replaced
/// ([Transaction], [Expense], [PlannerEvent], [Task], [Goal],
/// [ReportedEntry]) still persist one, but nothing reads it: it is
/// write-only dead data carried for round-trip compatibility. See
/// [Node.importExpense] for the legacy path.
class Node extends Equatable {
  static const int storageVersion = 1;

  final String id;
  final String title;
  final String? notes;
  final List<String> parentIds;
  final NodeStatus status;
  final DateTime? completedAt;
  final DateTime createdAt;

  /// True for abstract, unbounded goals: ongoing directions with no due
  /// date, no targets, and no progress bar. Additive flag, defaults to
  /// false, so every payload written before it existed loads as bounded.
  final bool isUnbounded;

  /// Whether this goal is part of the user-curated short list shown on the
  /// time-tracking card. Additive flag, defaults to true so existing goals
  /// stay tracked and old payloads load untouched.
  final bool isTracked;

  final ScheduleFacet? schedule;
  final MoneyFacet? money;
  final EffortFacet? effort;
  final AnkiFacet? anki;
  final NodeRecurrence? recurrence;
  final RuleFacet? rule;

  /// Template this was generated from, if any. Instances inherit the
  /// template's facets unless the field is listed in [overriddenFields].
  /// Linking a transaction makes an instance concrete (fields owned).
  final String? instanceOfId;
  final Set<String> overriddenFields;

  // Provenance for imported homework / calendar links. These are source
  // ids, not tags: they say where the node came from.
  final String? sourceEventId;
  final String? calendarEventId;
  final String? feedId;
  final String? classId;
  final String? classLabel;

  // Time reporting, mirroring Task actuals.
  final DateTime? actualStart;
  final DateTime? actualEnd;
  final DateTime? timerStartedAt;
  final List<TaskAssignee> assignees;

  const Node({
    required this.id,
    required this.title,
    this.notes,
    this.parentIds = const [],
    this.status = NodeStatus.open,
    this.completedAt,
    required this.createdAt,
    this.isUnbounded = false,
    this.isTracked = true,
    this.schedule,
    this.money,
    this.effort,
    this.anki,
    this.recurrence,
    this.rule,
    this.instanceOfId,
    this.overriddenFields = const {},
    this.sourceEventId,
    this.calendarEventId,
    this.feedId,
    this.classId,
    this.classLabel,
    this.actualStart,
    this.actualEnd,
    this.timerStartedAt,
    this.assignees = const [],
  });

  bool get isTemplate => recurrence != null && instanceOfId == null;
  bool get isInstance => instanceOfId != null;
  bool get isDone => status == NodeStatus.done;
  bool get isOpen => status == NodeStatus.open;
  bool get isTracking => timerStartedAt != null;
  bool get hasReported => actualStart != null && actualEnd != null;

  /// Imported homework marker: provenance-based, never tag-based.
  bool get isHomework =>
      sourceEventId != null || classId != null || feedId != null;

  bool get hasDue => schedule?.due != null;
  bool get hasCalendarBlock => schedule?.hasCalendarBlock ?? false;
  bool get hasMoney => money != null;
  bool get hasEffort => effort != null;
  bool get hasAnki => anki != null;

  Duration? get reportedDuration {
    final s = actualStart;
    final e = actualEnd;
    if (s == null || e == null || !e.isAfter(s)) return null;
    return e.difference(s);
  }

  /// The plan next to the occurrence, in one object.
  ///
  /// This is the Project Time Management Ontology's central comparison —
  /// what was scheduled against what actually happened — exposed once
  /// instead of being re-derived by each caller. The individual
  /// [ScheduleFacet.plannedDuration] and [reportedDuration] getters are
  /// kept because their return contracts differ (nullable vs.
  /// non-nullable on [PlannerEvent]); this is the one that can be
  /// compared directly.
  PlannedActual get plannedActual => PlannedActual(
        plannedStart: schedule?.start,
        plannedEnd: schedule?.end,
        actualStart: actualStart,
        actualEnd: actualEnd,
      );

  bool isOverdueAt(DateTime now) {
    final due = schedule?.due;
    if (due == null || isDone) return false;
    final today = DateTime(now.year, now.month, now.day);
    final dueDay = DateTime(due.year, due.month, due.day);
    return dueDay.isBefore(today);
  }

  Node copyWith({
    String? title,
    String? notes,
    bool clearNotes = false,
    List<String>? parentIds,
    NodeStatus? status,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    DateTime? createdAt,
    bool? isUnbounded,
    bool? isTracked,
    ScheduleFacet? schedule,
    bool clearSchedule = false,
    MoneyFacet? money,
    bool clearMoney = false,
    EffortFacet? effort,
    bool clearEffort = false,
    AnkiFacet? anki,
    bool clearAnki = false,
    NodeRecurrence? recurrence,
    bool clearRecurrence = false,
    RuleFacet? rule,
    bool clearRule = false,
    String? instanceOfId,
    bool clearInstanceOf = false,
    Set<String>? overriddenFields,
    String? sourceEventId,
    bool clearSourceEvent = false,
    String? calendarEventId,
    bool clearCalendarEvent = false,
    String? feedId,
    bool clearFeed = false,
    String? classId,
    bool clearClassId = false,
    String? classLabel,
    bool clearClassLabel = false,
    DateTime? actualStart,
    bool clearActualStart = false,
    DateTime? actualEnd,
    bool clearActualEnd = false,
    DateTime? timerStartedAt,
    bool clearTimerStartedAt = false,
    List<TaskAssignee>? assignees,
  }) =>
      Node(
        id: id,
        title: title ?? this.title,
        notes: clearNotes ? null : (notes ?? this.notes),
        parentIds: parentIds ?? this.parentIds,
        status: status ?? this.status,
        completedAt:
            clearCompletedAt ? null : (completedAt ?? this.completedAt),
        createdAt: createdAt ?? this.createdAt,
        isUnbounded: isUnbounded ?? this.isUnbounded,
        isTracked: isTracked ?? this.isTracked,
        schedule: clearSchedule ? null : (schedule ?? this.schedule),
        money: clearMoney ? null : (money ?? this.money),
        effort: clearEffort ? null : (effort ?? this.effort),
        anki: clearAnki ? null : (anki ?? this.anki),
        recurrence: clearRecurrence ? null : (recurrence ?? this.recurrence),
        rule: clearRule ? null : (rule ?? this.rule),
        instanceOfId:
            clearInstanceOf ? null : (instanceOfId ?? this.instanceOfId),
        overriddenFields: overriddenFields ?? this.overriddenFields,
        sourceEventId: clearSourceEvent
            ? null
            : (sourceEventId ?? this.sourceEventId),
        calendarEventId: clearCalendarEvent
            ? null
            : (calendarEventId ?? this.calendarEventId),
        feedId: clearFeed ? null : (feedId ?? this.feedId),
        classId: clearClassId ? null : (classId ?? this.classId),
        classLabel:
            clearClassLabel ? null : (classLabel ?? this.classLabel),
        actualStart:
            clearActualStart ? null : (actualStart ?? this.actualStart),
        actualEnd: clearActualEnd ? null : (actualEnd ?? this.actualEnd),
        timerStartedAt: clearTimerStartedAt
            ? null
            : (timerStartedAt ?? this.timerStartedAt),
        assignees: assignees ?? this.assignees,
      );

  /// Mark one field as owned by this node (stops inheriting it from the
  /// template). Permanent API, not a migration branch.
  Node withOverride(String field) =>
      copyWith(overriddenFields: {...overriddenFields, field});

  Node withoutOverride(String field) {
    final next = {...overriddenFields}..remove(field);
    return copyWith(overriddenFields: next);
  }

  factory Node.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'];
    if (rawId is! String || rawId.isEmpty) {
      throw const FormatException('Node needs an id');
    }
    DateTime createdAt = DateTime.fromMillisecondsSinceEpoch(0);
    final rawCreated = json['createdAt'];
    if (rawCreated is String) {
      createdAt = DateTime.tryParse(rawCreated) ?? createdAt;
    }
    return Node(
      id: rawId,
      title: (json['title'] as String?) ?? '',
      notes: json['notes'] as String?,
      parentIds: _stringList(json['parentIds']),
      status: NodeStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => NodeStatus.open,
      ),
      completedAt: _tryDate(json['completedAt']),
      createdAt: createdAt,
      // Missing (pre-flag payloads) reads as bounded, so old data loads
      // untouched and never trips [validateUnbounded]. The == true
      // coercion also survives wrong-typed values: a corrupt flag reads
      // as bounded instead of dropping the whole node.
      isUnbounded: json['isUnbounded'] == true,
      isTracked: () {
        final raw = json['isTracked'] ?? json['tracked'];
        if (raw == null) return true;
        return raw == true;
      }(),
      schedule: json['schedule'] is Map
          ? _facetOrNull(
              () => ScheduleFacet.fromJson(
                  Map<String, dynamic>.from(json['schedule'] as Map)))
          : null,
      money: json['money'] is Map
          ? _facetOrNull(() => MoneyFacet.fromJson(
              Map<String, dynamic>.from(json['money'] as Map)))
          : null,
      effort: json['effort'] is Map
          ? _facetOrNull(() => EffortFacet.fromJson(
              Map<String, dynamic>.from(json['effort'] as Map)))
          : null,
      anki: json['anki'] is Map
          ? _facetOrNull(() => AnkiFacet.fromJson(
              Map<String, dynamic>.from(json['anki'] as Map)))
          : null,
      recurrence: json['recurrence'] is Map
          ? _facetOrNull(() => NodeRecurrence.fromJson(
              Map<String, dynamic>.from(json['recurrence'] as Map)))
          : null,
      rule: json['rule'] is Map
          ? _facetOrNull(() => RuleFacet.fromJson(
              Map<String, dynamic>.from(json['rule'] as Map)))
          : null,
      instanceOfId: json['instanceOfId'] as String?,
      overriddenFields: _stringSet(json['overriddenFields']),
      sourceEventId: json['sourceEventId'] as String?,
      calendarEventId: json['calendarEventId'] as String?,
      feedId: json['feedId'] as String?,
      classId: json['classId'] as String?,
      classLabel: json['classLabel'] as String?,
      actualStart: _tryDate(json['actualStart']),
      actualEnd: _tryDate(json['actualEnd']),
      timerStartedAt: _tryDate(json['timerStartedAt']),
      assignees: _assigneesFromJson(json['assignees']),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': storageVersion,
        'id': id,
        'title': title,
        'notes': notes,
        'parentIds': parentIds,
        'status': status.name,
        'completedAt': completedAt?.toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
        'isUnbounded': isUnbounded,
        'isTracked': isTracked,
        'tracked': isTracked,
        'schedule': schedule?.toJson(),
        'money': money?.toJson(),
        'effort': effort?.toJson(),
        'anki': anki?.toJson(),
        'recurrence': recurrence?.toJson(),
        'rule': rule?.toJson(),
        'instanceOfId': instanceOfId,
        'overriddenFields': overriddenFields.toList(),
        'sourceEventId': sourceEventId,
        'calendarEventId': calendarEventId,
        'feedId': feedId,
        'classId': classId,
        'classLabel': classLabel,
        'actualStart': actualStart?.toIso8601String(),
        'actualEnd': actualEnd?.toIso8601String(),
        'timerStartedAt': timerStartedAt?.toIso8601String(),
        'assignees': assignees.map((a) => a.toJson()).toList(),
      };

  @override
  List<Object?> get props => [
        id,
        title,
        notes,
        parentIds,
        status,
        completedAt,
        createdAt,
        isUnbounded,
        isTracked,
        schedule,
        money,
        effort,
        anki,
        recurrence,
        rule,
        instanceOfId,
        overriddenFields,
        sourceEventId,
        calendarEventId,
        feedId,
        classId,
        classLabel,
        actualStart,
        actualEnd,
        timerStartedAt,
        assignees,
      ];
}

DateTime? _tryDate(Object? raw) {
  if (raw == null) return null;
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}

T? _facetOrNull<T>(T Function() parse) {
  try {
    return parse();
  } catch (_) {
    return null;
  }
}

List<String> _stringList(Object? raw) {
  if (raw is! List) return const [];
  final out = <String>[];
  for (final item in raw) {
    if (item is String && item.isNotEmpty) out.add(item);
  }
  return out;
}

Set<String> _stringSet(Object? raw) {
  if (raw is! List) return const {};
  final out = <String>{};
  for (final item in raw) {
    if (item is String && item.isNotEmpty) out.add(item);
  }
  return out;
}

List<TaskAssignee> _assigneesFromJson(Object? raw) {
  if (raw is! List) return const [];
  final out = <TaskAssignee>[];
  for (final item in raw) {
    if (item is! Map) continue;
    try {
      out.add(TaskAssignee.fromJson(Map<String, dynamic>.from(item)));
    } catch (_) {}
  }
  return out;
}
