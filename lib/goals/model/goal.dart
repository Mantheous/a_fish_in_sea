import 'package:equatable/equatable.dart';

import 'package:a_fish_in_sea/finances/model/budget.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';

enum GoalType { checklist, time, financial }

enum GoalStatus { unreported, completed, failed }

class Goal extends Equatable {
  final String id;
  final String title;
  final String? notes;
  final GoalType type;
  final String? parentId;
  final List<String> tagIds;
  final DateTime startDate;
  final DateTime deadline;
  final bool done;
  final DateTime? completedAt;
  final bool failed;
  final bool showInTasks;
  final int? targetMinutes;
  final double? targetAmount;
  final TimeScale? period;
  final int? customPeriodDays;
  final bool isRecurring;
  final bool autoRollover;
  final double rolloverAmount;

  const Goal({
    required this.id,
    required this.title,
    this.notes,
    required this.type,
    this.parentId,
    this.tagIds = const [],
    required this.startDate,
    required this.deadline,
    this.done = false,
    this.completedAt,
    this.failed = false,
    this.showInTasks = false,
    this.targetMinutes,
    this.targetAmount,
    this.period,
    this.customPeriodDays,
    this.isRecurring = true,
    this.autoRollover = true,
    this.rolloverAmount = 0.0,
  });

  double get effectiveAmount => (targetAmount ?? 0) + rolloverAmount;

  bool get isLeafChecklistTask => type == GoalType.checklist && showInTasks;

  Goal copyWith({
    String? title,
    String? notes,
    bool clearNotes = false,
    GoalType? type,
    String? parentId,
    bool clearParent = false,
    List<String>? tagIds,
    DateTime? startDate,
    DateTime? deadline,
    bool? done,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    bool? failed,
    bool? showInTasks,
    int? targetMinutes,
    bool clearTargetMinutes = false,
    double? targetAmount,
    bool clearTargetAmount = false,
    TimeScale? period,
    bool clearPeriod = false,
    int? customPeriodDays,
    bool clearCustomPeriod = false,
    bool? isRecurring,
    bool? autoRollover,
    double? rolloverAmount,
  }) =>
      Goal(
        id: id,
        title: title ?? this.title,
        notes: clearNotes ? null : (notes ?? this.notes),
        type: type ?? this.type,
        parentId: clearParent ? null : (parentId ?? this.parentId),
        tagIds: tagIds ?? this.tagIds,
        startDate: startDate ?? this.startDate,
        deadline: deadline ?? this.deadline,
        done: done ?? this.done,
        completedAt:
            clearCompletedAt ? null : (completedAt ?? this.completedAt),
        failed: failed ?? this.failed,
        showInTasks: showInTasks ?? this.showInTasks,
        targetMinutes: clearTargetMinutes
            ? null
            : (targetMinutes ?? this.targetMinutes),
        targetAmount:
            clearTargetAmount ? null : (targetAmount ?? this.targetAmount),
        period: clearPeriod ? null : (period ?? this.period),
        customPeriodDays: clearCustomPeriod
            ? null
            : (customPeriodDays ?? this.customPeriodDays),
        isRecurring: isRecurring ?? this.isRecurring,
        autoRollover: autoRollover ?? this.autoRollover,
        rolloverAmount: rolloverAmount ?? this.rolloverAmount,
      );

  factory Goal.fromJson(Map<String, dynamic> json) {
    final startRaw = json['startDate'] as String?;
    final deadlineRaw = json['deadline'] as String?;
    return Goal(
      id: json['id'] as String,
      title: json['title'] as String,
      notes: json['notes'] as String?,
      type: GoalType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => GoalType.checklist,
      ),
      parentId: json['parentId'] as String?,
      tagIds: _tagIdsFromJson(json['tagIds']),
      startDate: startRaw == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : (DateTime.tryParse(startRaw) ??
              DateTime.fromMillisecondsSinceEpoch(0)),
      deadline: deadlineRaw == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : (DateTime.tryParse(deadlineRaw) ??
              DateTime.fromMillisecondsSinceEpoch(0)),
      done: json['done'] as bool? ?? false,
      completedAt: json['completedAt'] == null
          ? null
          : DateTime.tryParse(json['completedAt'] as String),
      failed: json['failed'] as bool? ?? false,
      showInTasks: json['showInTasks'] as bool? ?? false,
      targetMinutes: (json['targetMinutes'] as num?)?.toInt(),
      targetAmount: (json['targetAmount'] as num?)?.toDouble(),
      period: json['period'] == null
          ? null
          : TimeScale.values.firstWhere(
              (e) => e.name == json['period'],
              orElse: () => TimeScale.monthly,
            ),
      customPeriodDays: (json['customPeriodDays'] as num?)?.toInt(),
      isRecurring: json['isRecurring'] as bool? ?? true,
      autoRollover: json['autoRollover'] as bool? ?? true,
      rolloverAmount: (json['rolloverAmount'] as num?)?.toDouble() ?? 0.0,
    );
  }

  factory Goal.fromBudget(Budget budget) => Goal(
        id: 'goal:${budget.id}',
        title: budget.name,
        type: GoalType.financial,
        tagIds: const [],
        startDate: budget.startDate,
        deadline: budget.endDate ?? budget.startDate.add(
          const Duration(days: 30),
        ),
        targetAmount: budget.goalAmount,
        period: budget.period,
        customPeriodDays: budget.customPeriodDays,
        isRecurring: budget.isRecurring,
        autoRollover: budget.autoRollover,
        rolloverAmount: budget.rolloverAmount,
        notes: 'Imported budget category: ${budget.category}',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'notes': notes,
        'type': type.name,
        'parentId': parentId,
        'tagIds': tagIds,
        'startDate': startDate.toIso8601String(),
        'deadline': deadline.toIso8601String(),
        'done': done,
        'completedAt': completedAt?.toIso8601String(),
        'failed': failed,
        'showInTasks': showInTasks,
        'targetMinutes': targetMinutes,
        'targetAmount': targetAmount,
        'period': period?.name,
        'customPeriodDays': customPeriodDays,
        'isRecurring': isRecurring,
        'autoRollover': autoRollover,
        'rolloverAmount': rolloverAmount,
      };

  @override
  List<Object?> get props => [
        id,
        title,
        notes,
        type,
        parentId,
        tagIds,
        startDate,
        deadline,
        done,
        completedAt,
        failed,
        showInTasks,
        targetMinutes,
        targetAmount,
        period,
        customPeriodDays,
        isRecurring,
        autoRollover,
        rolloverAmount,
      ];

  static List<String> _tagIdsFromJson(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final item in raw) {
      if (item is String && item.isNotEmpty) out.add(item);
    }
    return out;
  }
}

bool canNest(GoalType parent, GoalType child) {
  if (parent == GoalType.checklist) return true;
  return parent == child;
}

bool spanFitsParent({
  required DateTime childStart,
  required DateTime childDeadline,
  required DateTime parentStart,
  required DateTime parentDeadline,
}) {
  if (childDeadline.isBefore(childStart)) return false;
  if (childStart.isBefore(parentStart)) return false;
  if (childDeadline.isAfter(parentDeadline)) return false;
  return true;
}

enum DeadlineBucket { all, shortTerm, longTerm, overdue }

DeadlineBucket bucketFor(DateTime deadline, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  if (deadline.isBefore(today)) return DeadlineBucket.overdue;
  final daysOut = deadline.difference(today).inDays;
  if (daysOut <= 30) return DeadlineBucket.shortTerm;
  return DeadlineBucket.longTerm;
}
