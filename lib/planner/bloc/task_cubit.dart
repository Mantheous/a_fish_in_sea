import '../../common/undo/revertable_hydrated_cubit.dart';
import '../model/feed.dart';
import '../model/planner_event.dart';
import '../model/task.dart';

/// Substrings marking a Learning Suite event as an assignment worth a task.
/// Learning Suite feeds mix class topics ("England", "Feminist Criticism")
/// with real homework and carry no machine-readable distinction (unlike
/// Canvas `event-assignment-*` UIDs), so only titles containing one of
/// these (case-insensitive) become tasks.
const _learningSuiteAssignmentHints = <String>[
  'read',
  'watch',
  'video',
  'post',
  'submit',
  'due',
  'turn in',
  'take',
  'midterm',
  'exam',
  'quiz',
  'assign',
  'homework',
  'record',
  'complet',
  'fill',
  'writ',
  'essay',
  'paper',
  'project',
  'present',
  'discuss',
  'email',
  'bring',
  'page',
  'chapter',
  'study',
  'task',
  'survey',
  'credit',
];

bool looksLikeLearningSuiteAssignment(String title) {
  final lower = title.toLowerCase();
  return _learningSuiteAssignmentHints.any(lower.contains);
}

/// Whether a feed event qualifies as a task (same rule [TaskCubit.importFromFeed]
/// uses to create shadow tasks). Extracted so [FeedCubit] can mark
/// [PlannerEvent.isTask] with the identical heuristic.
bool isTaskCandidate(PlannerEvent event, Feed feed, DateTime now) {
  final cutoff =
      now.subtract(const Duration(days: TaskCubit.importLookbackDays));
  if (event.start.isBefore(cutoff)) return false;
  if (feed.kind == FeedKind.canvas &&
      !(event.sourceUid?.startsWith('event-assignment-') ?? false)) {
    return false;
  }
  if (feed.kind == FeedKind.learningSuite &&
      !looksLikeLearningSuiteAssignment(event.subject)) {
    return false;
  }
  return true;
}

class TaskCubit extends RevertableHydratedCubit<List<Task>> {
  TaskCubit() : super(const []);

  static const int importLookbackDays = 7;
  void addTask(Task task) => emitChange([...state, task]);

  void updateTask(Task task) =>
      emitChange(state.map((t) => t.id == task.id ? task : t).toList());

  void deleteTask(String taskId) =>
      emitChange(state.where((t) => t.id != taskId).toList());

  void toggleDone(String taskId) {
    final task = byId(taskId);
    if (task == null) return;
    final now = DateTime.now();
    final updated = task.done
        ? task.copyWith(done: false, clearCompletedAt: true)
        : task.copyWith(done: true, completedAt: now);
    updateTask(updated);
  }

  void setCalendarEvent(String taskId, String eventId) {
    final task = byId(taskId);
    if (task == null) return;
    if (task.calendarEventId == eventId) return;
    updateTask(task.copyWith(calendarEventId: eventId));
  }

  void clearCalendarEvent(String taskId) {
    final task = byId(taskId);
    if (task == null || task.calendarEventId == null) return;
    updateTask(task.copyWith(clearCalendarEventId: true));
  }

  void clearCalendarEventForEvent(String eventId) {
    for (final task in state) {
      if (task.calendarEventId == eventId) {
        updateTask(task.copyWith(clearCalendarEventId: true));
      }
    }
  }

  /// All tasks backing a task-event: personal links ([Task.calendarEventId])
  /// and imported homework shadows ([Task.sourceEventId]).
  List<Task> tasksForEventId(String eventId) => state
      .where((t) =>
          t.calendarEventId == eventId || t.sourceEventId == eventId)
      .toList();

  Task? taskForCalendarEvent(String eventId) {
    for (final task in state) {
      if (task.calendarEventId == eventId) return task;
    }
    return null;
  }

  /// Creates or refreshes the personal linked task for [event] so the event
  /// shows up in the Tasks list. Returns the task id. Title/notes/due/done
  /// mirror the event; completion is kept in sync both ways by the caller.
  String upsertLinkedTaskForEvent(PlannerEvent event) {
    if (event.taskId != null) {
      final linked = byId(event.taskId!);
      if (linked != null) {
        final hasNotes =
            (event.notes ?? '').trim().isNotEmpty;
        updateTask(
          linked.copyWith(
            title: event.subject,
            notes: hasNotes ? event.notes!.trim() : null,
            clearNotes: !hasNotes,
            due: event.start,
            done: event.done,
            completedAt: event.completedAt,
            clearCompletedAt:
                !event.done || event.completedAt == null,
          ),
        );
        return linked.id;
      }
    }
    final byCalendar = taskForCalendarEvent(event.id);
    if (byCalendar != null) {
      final hasNotes = (event.notes ?? '').trim().isNotEmpty;
      updateTask(
        byCalendar.copyWith(
          title: event.subject,
          notes: hasNotes ? event.notes!.trim() : null,
          clearNotes: !hasNotes,
          due: event.start,
          done: event.done,
          completedAt: event.completedAt,
          clearCompletedAt: !event.done || event.completedAt == null,
        ),
      );
      return byCalendar.id;
    }
    final id = 'task:${event.id}';
    addTask(Task(
      id: id,
      title: event.subject,
      notes: event.notes,
      due: event.start,
      done: event.done,
      completedAt: event.completedAt,
      classLabel: event.classLabel,
      calendarEventId: event.id,
    ));
    return id;
  }

  /// Mirrors an event's completion onto every backing task.
  void setDoneForEvent(
    String eventId, {
    required bool done,
    DateTime? completedAt,
  }) {
    for (final task in tasksForEventId(eventId)) {
      if (task.done == done &&
          (done || task.completedAt == null) &&
          (task.completedAt == completedAt ||
              (!done && completedAt == null))) {
        continue;
      }
      updateTask(
        task.copyWith(
          done: done,
          completedAt: completedAt,
          clearCompletedAt: !done,
        ),
      );
    }
  }

  /// Ensures an imported-style shadow task exists for a feed event that was
  /// manually marked as a task (e.g. a class session the user promotes, or
  /// a feed with "create tasks" off). Mirrors the event's completion state.
  void ensureShadowForFeedEvent(PlannerEvent event) {
    if (event.feedId == null) return;
    final existing = tasksForEventId(event.id);
    if (existing.isNotEmpty) {
      for (final task in existing) {
        if (task.done != event.done ||
            task.completedAt != event.completedAt) {
          updateTask(
            task.copyWith(
              done: event.done,
              completedAt: event.completedAt,
              clearCompletedAt: !event.done,
            ),
          );
        }
      }
      return;
    }
    addTask(Task(
      id: event.id,
      title: event.subject,
      notes: event.notes,
      due: event.start,
      done: event.done,
      completedAt: event.completedAt,
      sourceEventId: event.id,
      classId: event.feedId,
      classLabel: event.classLabel,
    ));
  }

  /// Deletes every task backing [eventId] (personal link and/or homework
  /// shadow). Used when an event is deleted or un-marked as a task.
  void removeTasksForEvent(String eventId) {
    final ids =
        tasksForEventId(eventId).map((t) => t.id).toSet();
    if (ids.isEmpty) return;
    emitChange(state.where((t) => !ids.contains(t.id)).toList());
  }

  Task? byId(String taskId) {
    for (final task in state) {
      if (task.id == taskId) return task;
    }
    return null;
  }

  List<Task> get openTasks {
    final open = state.where((t) => !t.done).toList()
      ..sort(_byDueThenCreated);
    final done = state.where((t) => t.done).toList()
      ..sort((a, b) =>
          (b.completedAt ?? DateTime(0)).compareTo(a.completedAt ?? DateTime(0)));
    return [...open, ...done];
  }

  List<Task> get overdueAndToday {
    return state.where((t) => !t.done && (t.isOverdue || t.isDueToday)).toList()
      ..sort(_byDueThenCreated);
  }

  /// Open tasks due in the next 7 days (start of today through the end of
  /// the 7th day out). Used by the Home dashboard's week section.
  List<Task> get dueThisWeek {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final endExclusive = today.add(const Duration(days: 8));
    return state
        .where((t) =>
            !t.done &&
            t.due != null &&
            !t.due!.isBefore(today) &&
            t.due!.isBefore(endExclusive))
        .toList()
      ..sort(_byDueThenCreated);
  }

  int _byDueThenCreated(Task a, Task b) {
    final aDue = a.due;
    final bDue = b.due;
    if (aDue == null && bDue == null) return 0;
    if (aDue == null) return 1;
    if (bDue == null) return -1;
    return aDue.compareTo(bDue);
  }

  void importFromFeed(
    List<PlannerEvent> events,
    Feed feed, {
    Set<String> taskOptOutIds = const {},
  }) {
    final now = DateTime.now();
    var base = state;
    if (feed.kind == FeedKind.learningSuite) {
      // Drop previously imported open tasks that don't look like
      // assignments so a resync cleans up topic clutter. Done tasks are
      // kept to preserve the user's completion history.
      base = base
          .where(
            (t) =>
                t.classId != feed.id ||
                !t.isImported ||
                t.done ||
                looksLikeLearningSuiteAssignment(t.title),
          )
          .toList();
    }
    final existing = base.map((t) => t.id).toSet();
    final existingSource = base
        .map((t) => t.sourceEventId)
        .whereType<String>()
        .toSet();
    final imported = <Task>[];
    for (final event in events) {
      if (taskOptOutIds.contains(event.id)) continue;
      if (!isTaskCandidate(event, feed, now)) continue;
      if (existingSource.contains(event.id)) continue;
      if (existing.contains(event.id)) continue;
      imported.add(Task(
        id: event.id,
        title: event.subject,
        notes: event.notes,
        due: event.start,
        done: event.done,
        completedAt: event.completedAt,
        sourceEventId: event.id,
        classId: feed.id,
        classLabel: event.classLabel,
      ));
    }
    final next = [...base, ...imported];
    if (imported.isNotEmpty || next.length != state.length) {
      emit(next);
    }
  }

  void removeImportedTasksFor(String feedId) {
    emit(
      state
          .where((t) => !(t.classId == feedId && t.isImported))
          .toList(),
    );
  }

  @override
  List<Task>? fromJson(Map<String, dynamic> json) {
    final list = json['tasks'] as List<dynamic>?;
    return list
        ?.map((t) => Task.fromJson(t as Map<String, dynamic>))
        .toList();
  }

  @override
  Map<String, dynamic> toJson(List<Task> state) =>
      {'tasks': state.map((t) => t.toJson()).toList()};
}
