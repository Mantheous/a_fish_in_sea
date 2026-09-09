import 'package:equatable/equatable.dart';

import 'task_assignee.dart';

class PlannerEvent extends Equatable {
  final String id;
  final String subject;
  final String? notes;
  final String? location;
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String recurrenceRule;
  final String? feedId;
  final String? sourceUid;
  final String? seriesId;
  final String? classLabel;
  final int? colorValue;
  final String? taskId;
  final bool isTask;
  final bool done;
  final DateTime? completedAt;
  final String? placeId;
  final DateTime? actualStart;
  final DateTime? actualEnd;
  final DateTime? timerStartedAt;
  final bool failed;
  final List<TaskAssignee> assignees;
  final List<String> tagIds;

  const PlannerEvent({
    required this.id,
    required this.subject,
    this.notes,
    this.location,
    required this.start,
    required this.end,
    this.allDay = false,
    this.recurrenceRule = '',
    this.feedId,
    this.sourceUid,
    this.seriesId,
    this.classLabel,
    this.colorValue,
    this.taskId,
    this.isTask = false,
    this.done = false,
    this.completedAt,
    this.placeId,
    this.actualStart,
    this.actualEnd,
    this.timerStartedAt,
    this.failed = false,
    this.assignees = const [],
    this.tagIds = const [],
  });

  bool get isFromFeed => feedId != null;

  bool get isRecurringInstance => seriesId != null && seriesId!.isNotEmpty;

  bool get isTracking => timerStartedAt != null;

  bool get hasReported => actualStart != null && actualEnd != null;

  Duration get plannedDuration =>
      end.isAfter(start) ? end.difference(start) : Duration.zero;

  Duration? get reportedDuration {
    final s = actualStart;
    final e = actualEnd;
    if (s == null || e == null || !e.isAfter(s)) return null;
    return e.difference(s);
  }

  DateTime get endOfDay {
    if (!allDay) return end;
    return DateTime(end.year, end.month, end.day, 23, 59, 59);
  }

  PlannerEvent copyWith({
    String? subject,
    String? notes,
    bool clearNotes = false,
    String? location,
    bool clearLocation = false,
    DateTime? start,
    DateTime? end,
    bool? allDay,
    String? recurrenceRule,
    int? colorValue,
    bool clearColorValue = false,
    String? taskId,
    bool clearTaskId = false,
    bool? isTask,
    bool? done,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    String? placeId,
    bool clearPlaceId = false,
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
      PlannerEvent(
        id: id,
        subject: subject ?? this.subject,
        notes: clearNotes ? null : (notes ?? this.notes),
        location: clearLocation ? null : (location ?? this.location),
        start: start ?? this.start,
        end: end ?? this.end,
        allDay: allDay ?? this.allDay,
        recurrenceRule: recurrenceRule ?? this.recurrenceRule,
        feedId: feedId,
        sourceUid: sourceUid,
        seriesId: seriesId,
        classLabel: classLabel,
        colorValue:
            clearColorValue ? null : (colorValue ?? this.colorValue),
        taskId: clearTaskId ? null : (taskId ?? this.taskId),
        isTask: isTask ?? this.isTask,
        done: done ?? this.done,
        completedAt: clearCompletedAt
            ? null
            : (completedAt ?? this.completedAt),
        placeId: clearPlaceId ? null : (placeId ?? this.placeId),
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

  factory PlannerEvent.fromJson(Map<String, dynamic> json) => PlannerEvent(
        id: json['id'] as String,
        subject: json['subject'] as String,
        notes: json['notes'] as String?,
        location: json['location'] as String?,
        start: DateTime.parse(json['start'] as String),
        end: DateTime.parse(json['end'] as String),
        allDay: json['allDay'] as bool? ?? false,
        recurrenceRule: json['recurrenceRule'] as String? ?? '',
        feedId: json['feedId'] as String?,
        sourceUid: json['sourceUid'] as String?,
        seriesId: json['seriesId'] as String?,
        classLabel: json['classLabel'] as String?,
        colorValue: json['colorValue'] as int?,
        taskId: json['taskId'] as String?,
        isTask: json['isTask'] as bool? ?? false,
        done: json['done'] as bool? ?? false,
        completedAt: json['completedAt'] == null
            ? null
            : DateTime.parse(json['completedAt'] as String),
        placeId: json['placeId'] as String?,
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
        'subject': subject,
        'notes': notes,
        'location': location,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'allDay': allDay,
        'recurrenceRule': recurrenceRule,
        'feedId': feedId,
        'sourceUid': sourceUid,
        'seriesId': seriesId,
        'classLabel': classLabel,
        'colorValue': colorValue,
        'taskId': taskId,
        'isTask': isTask,
        'done': done,
        'completedAt': completedAt?.toIso8601String(),
        'placeId': placeId,
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
        subject,
        notes,
        location,
        start,
        end,
        allDay,
        recurrenceRule,
        feedId,
        sourceUid,
        seriesId,
        classLabel,
        colorValue,
        taskId,
        isTask,
        done,
        completedAt,
        placeId,
        actualStart,
        actualEnd,
        timerStartedAt,
        failed,
        assignees,
        tagIds,
      ];
}
