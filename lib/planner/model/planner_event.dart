import 'package:equatable/equatable.dart';

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
  });

  bool get isFromFeed => feedId != null;

  bool get isRecurringInstance => seriesId != null && seriesId!.isNotEmpty;

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
      );

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
      ];
}
