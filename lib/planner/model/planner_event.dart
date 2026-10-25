import 'package:equatable/equatable.dart';

import 'package:a_fish_in_sea/common/time/local_date.dart';
import 'package:a_fish_in_sea/common/time/planned_actual.dart';
import 'package:a_fish_in_sea/common/time/time_session.dart';

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

  /// Every completed run of the timer, oldest first. Legacy
  /// [actualStart]/[actualEnd] stay the aggregate span for readers that
  /// predate sessions; old payloads have no `sessions` key and are lifted
  /// on read by [recordedSessions].
  final List<TimeSession> sessions;
  final DateTime? actualStart;
  final DateTime? actualEnd;
  final DateTime? timerStartedAt;
  final bool failed;
  final List<TaskAssignee> assignees;
  final List<String> tagIds;
  final int? reminderMinutesBefore;

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
    this.sessions = const [],
    this.actualStart,
    this.actualEnd,
    this.timerStartedAt,
    this.failed = false,
    this.assignees = const [],
    this.tagIds = const [],
    this.reminderMinutesBefore,
  });

  bool get isFromFeed => feedId != null;

  bool get isRecurringInstance => seriesId != null && seriesId!.isNotEmpty;

  bool get isTracking => timerStartedAt != null;

  /// Every recorded run, oldest first. Falls back to the legacy single
  /// interval when a payload predates [sessions]. Once a payload carries an
  /// explicit list, that list is authoritative: the legacy pair is only its
  /// aggregate span, and lifting it too would count the gaps as work.
  List<TimeSession> get recordedSessions {
    if (sessions.isNotEmpty) return sessions;
    final legacy = TimeSession.legacySession(actualStart, actualEnd);
    return legacy == null ? const [] : [legacy];
  }

  bool get hasReported => recordedSessions.isNotEmpty;

  /// The plan next to the occurrence, in one object — same comparison
  /// [Node.plannedActual] exposes, so an event and its backing node can
  /// be asked the same question. Unlike [Node], an event's planned and
  /// actual times sit on the same record; the getter puts them behind the
  /// one interface both sides share.
  PlannedActual get plannedActual => PlannedActual(
    plannedStart: start,
    plannedEnd: end,
    actualStart: actualStart,
    actualEnd: actualEnd,
  );

  bool get hasReminder =>
      reminderMinutesBefore != null && reminderMinutesBefore! > 0;

  Duration get plannedDuration =>
      end.isAfter(start) ? end.difference(start) : Duration.zero;

  /// Total time across every recorded session — not the aggregate span,
  /// which would count the gaps between sessions as work.
  Duration? get reportedDuration => totalSessionDuration(recordedSessions);

  DateTime get endOfDay {
    if (!allDay) return end;
    final day = localDay(end);
    return DateTime(day.year, day.month, day.day, 23, 59, 59);
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
    List<TimeSession>? sessions,
    DateTime? actualStart,
    bool clearActualStart = false,
    DateTime? actualEnd,
    bool clearActualEnd = false,
    DateTime? timerStartedAt,
    bool clearTimerStartedAt = false,
    bool? failed,
    List<TaskAssignee>? assignees,
    List<String>? tagIds,
    int? reminderMinutesBefore,
    bool clearReminder = false,
  }) => PlannerEvent(
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
    colorValue: clearColorValue ? null : (colorValue ?? this.colorValue),
    taskId: clearTaskId ? null : (taskId ?? this.taskId),
    isTask: isTask ?? this.isTask,
    done: done ?? this.done,
    completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
    placeId: clearPlaceId ? null : (placeId ?? this.placeId),
    sessions: sessions ?? this.sessions,
    actualStart: clearActualStart ? null : (actualStart ?? this.actualStart),
    actualEnd: clearActualEnd ? null : (actualEnd ?? this.actualEnd),
    timerStartedAt: clearTimerStartedAt
        ? null
        : (timerStartedAt ?? this.timerStartedAt),
    failed: failed ?? this.failed,
    assignees: assignees ?? this.assignees,
    tagIds: tagIds ?? this.tagIds,
    reminderMinutesBefore: clearReminder
        ? null
        : (reminderMinutesBefore ?? this.reminderMinutesBefore),
  );

  factory PlannerEvent.fromJson(Map<String, dynamic> json) => PlannerEvent(
        id: json['id'] as String,
        subject: json['subject'] as String,
        notes: json['notes'] as String?,
        location: json['location'] as String?,
        start: DateTime.parse(json['start'] as String).toLocal(),
        end: DateTime.parse(json['end'] as String).toLocal(),
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
            : DateTime.parse(json['completedAt'] as String).toLocal(),
        placeId: json['placeId'] as String?,
        sessions: TimeSession.listFromJson(json['sessions']),
        actualStart: _tryTimerDate(json['actualStart']),
        actualEnd: _tryTimerDate(json['actualEnd']),
        timerStartedAt: _tryTimerDate(json['timerStartedAt']),
        failed: json['failed'] as bool? ?? false,
        assignees: _assigneesFromJson(json['assignees']),
        tagIds: _tagIdsFromJson(json['tagIds']),
        reminderMinutesBefore:
            _reminderFromJson(json['reminderMinutesBefore']),
      );

  static int? _reminderFromJson(Object? raw) {
    if (raw == null) return null;
    final parsed = raw is num ? raw.toInt() : int.tryParse('$raw');
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }

  /// Timer instants serialize as UTC strings (so they compare across
  /// timezones) but live in state as local times: normalize back on read.
  /// Pre-offset payloads already parse as local; [toLocal] is a no-op.
  static DateTime? _tryTimerDate(Object? raw) {
    if (raw == null) return null;
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

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
    'sessions': sessions.map((s) => s.toJson()).toList(),
    'actualStart': actualStart?.toUtc().toIso8601String(),
    'actualEnd': actualEnd?.toUtc().toIso8601String(),
    'timerStartedAt': timerStartedAt?.toUtc().toIso8601String(),
    'failed': failed,
    'assignees': assignees.map((a) => a.toJson()).toList(),
    'tagIds': tagIds,
    'reminderMinutesBefore': reminderMinutesBefore,
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
    sessions,
    actualStart,
    actualEnd,
    timerStartedAt,
    failed,
    assignees,
    tagIds,
    reminderMinutesBefore,
  ];
}
