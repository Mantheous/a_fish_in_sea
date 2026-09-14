import 'package:equatable/equatable.dart';

import 'task_assignee.dart';

class Task extends Equatable {
  final String id;
  final String title;
  final String? notes;
  final DateTime? due;
  final bool done;
  final DateTime? completedAt;
  final String? sourceEventId;
  final String? classId;
  final String? classLabel;
  final String? calendarEventId;
  final DateTime? plannedStart;
  final DateTime? plannedEnd;
  final DateTime? actualStart;
  final DateTime? actualEnd;
  final DateTime? timerStartedAt;
  final bool failed;
  final List<TaskAssignee> assignees;
  final List<String> tagIds;

  const Task({
    required this.id,
    required this.title,
    this.notes,
    this.due,
    this.done = false,
    this.completedAt,
    this.sourceEventId,
    this.classId,
    this.classLabel,
    this.calendarEventId,
    this.plannedStart,
    this.plannedEnd,
    this.actualStart,
    this.actualEnd,
    this.timerStartedAt,
    this.failed = false,
    this.assignees = const [],
    this.tagIds = const [],
  });

  bool get isImported => sourceEventId != null;

  bool get hasCalendarEvent => calendarEventId != null;

  bool get isTracking => timerStartedAt != null;

  bool get hasReported => actualStart != null && actualEnd != null;

  bool get hasPlanned => plannedStart != null && plannedEnd != null;

  Duration? get reportedDuration {
    final s = actualStart;
    final e = actualEnd;
    if (s == null || e == null || !e.isAfter(s)) return null;
    return e.difference(s);
  }

  Duration? get plannedDuration {
    final s = plannedStart;
    final e = plannedEnd;
    if (s == null || e == null || !e.isAfter(s)) return null;
    return e.difference(s);
  }

  bool get isOverdue {
    if (done || due == null) return false;
    final now = DateTime.now();
    return due!.isBefore(DateTime(now.year, now.month, now.day));
  }

  bool get isDueToday {
    if (done || due == null) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return !due!.isBefore(today) &&
        due!.isBefore(today.add(const Duration(days: 1)));
  }

  Task copyWith({
    String? title,
    String? notes,
    bool clearNotes = false,
    DateTime? due,
    bool clearDue = false,
    bool? done,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    String? calendarEventId,
    bool clearCalendarEventId = false,
    DateTime? plannedStart,
    bool clearPlannedStart = false,
    DateTime? plannedEnd,
    bool clearPlannedEnd = false,
    DateTime? actualStart,
    bool clearActualStart = false,
    DateTime? actualEnd,
    bool clearActualEnd = false,
    DateTime? timerStartedAt,
    bool clearTimerStartedAt = false,
    bool? failed,
    List<TaskAssignee>? assignees,
    List<String>? tagIds,
  }) =>
      Task(
        id: id,
        title: title ?? this.title,
        notes: clearNotes ? null : (notes ?? this.notes),
        due: clearDue ? null : (due ?? this.due),
        done: done ?? this.done,
        completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
        sourceEventId: sourceEventId,
        classId: classId,
        classLabel: classLabel,
        calendarEventId: clearCalendarEventId
            ? null
            : (calendarEventId ?? this.calendarEventId),
        plannedStart:
            clearPlannedStart ? null : (plannedStart ?? this.plannedStart),
        plannedEnd: clearPlannedEnd ? null : (plannedEnd ?? this.plannedEnd),
        actualStart:
            clearActualStart ? null : (actualStart ?? this.actualStart),
        actualEnd: clearActualEnd ? null : (actualEnd ?? this.actualEnd),
        timerStartedAt: clearTimerStartedAt
            ? null
            : (timerStartedAt ?? this.timerStartedAt),
        failed: failed ?? this.failed,
        assignees: assignees ?? this.assignees,
        tagIds: tagIds ?? this.tagIds,
      );

  factory Task.fromJson(Map<String, dynamic> json) => Task(
        id: json['id'] as String,
        title: json['title'] as String,
        notes: json['notes'] as String?,
        due: json['due'] == null ? null : DateTime.parse(json['due'] as String),
        done: json['done'] as bool? ?? false,
        completedAt: json['completedAt'] == null
            ? null
            : DateTime.parse(json['completedAt'] as String),
        sourceEventId: json['sourceEventId'] as String?,
        classId: json['classId'] as String?,
        classLabel: json['classLabel'] as String?,
        calendarEventId: json['calendarEventId'] as String?,
        plannedStart: json['plannedStart'] == null
            ? null
            : DateTime.tryParse(json['plannedStart'] as String),
        plannedEnd: json['plannedEnd'] == null
            ? null
            : DateTime.tryParse(json['plannedEnd'] as String),
        actualStart: json['actualStart'] == null
            ? null
            : DateTime.tryParse(json['actualStart'] as String),
        actualEnd: json['actualEnd'] == null
            ? null
            : DateTime.tryParse(json['actualEnd'] as String),
        timerStartedAt: json['timerStartedAt'] == null
            ? null
            : DateTime.tryParse(json['timerStartedAt'] as String),
        failed: json['failed'] as bool? ?? false,
        assignees: _assigneesFromJson(json['assignees']),
        tagIds: _tagIdsFromJson(json['tagIds']),
      );

  static List<String> _tagIdsFromJson(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final item in raw) {
      if (item is String && item.isNotEmpty) out.add(item);
    }
    return out;
  }

  static List<TaskAssignee> _assigneesFromJson(Object? raw) {
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'notes': notes,
        'due': due?.toIso8601String(),
        'done': done,
        'completedAt': completedAt?.toIso8601String(),
        'sourceEventId': sourceEventId,
        'classId': classId,
        'classLabel': classLabel,
        'calendarEventId': calendarEventId,
        'plannedStart': plannedStart?.toIso8601String(),
        'plannedEnd': plannedEnd?.toIso8601String(),
        'actualStart': actualStart?.toIso8601String(),
        'actualEnd': actualEnd?.toIso8601String(),
        'timerStartedAt': timerStartedAt?.toIso8601String(),
        'failed': failed,
        'assignees': assignees.map((a) => a.toJson()).toList(),
        'tagIds': tagIds,
      };

  @override
  List<Object?> get props => [
        id,
        title,
        notes,
        due,
        done,
        completedAt,
        sourceEventId,
        classId,
        classLabel,
        calendarEventId,
        plannedStart,
        plannedEnd,
        actualStart,
        actualEnd,
        timerStartedAt,
        failed,
        assignees,
        tagIds,
      ];
}
