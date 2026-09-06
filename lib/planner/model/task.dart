import 'package:equatable/equatable.dart';

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
  });

  bool get isImported => sourceEventId != null;

  bool get hasCalendarEvent => calendarEventId != null;

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
      );

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
      ];
}
