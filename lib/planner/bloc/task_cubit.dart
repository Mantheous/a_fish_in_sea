import '../../common/undo/revertable_hydrated_cubit.dart';
import '../model/feed.dart';
import '../model/planner_event.dart';
import '../model/task.dart';
import '../model/task_assignee.dart';

/// Whether a Learning Suite event is a gradebook item worth a task.
///
/// Learning Suite merges two different things into one iCal feed, with no
/// machine-readable distinction (unlike Canvas `event-assignment-*` UIDs):
///
/// - Assignment/quiz/exam objects (graded). These either carry a
///   DTSTART..DTEND open window (e.g. "Homework 5", "Unit 1 Reading
///   Points", "Video Quiz Section 2") or are due-date-only items with an
///   empty DESCRIPTION (e.g. "Homework Section 31", "Quiz 1",
///   "YPoll Quiz 9/2", "Final Exam").
/// - Schedule/commentary entries for a class day: lecture topics
///   ("England", "Feminist Criticism"), prep notes ("Bring your copy of
///   The Tempest"), daily nudges ("Post 2-3 times on DD ..."). These always
///   echo the day's text in DESCRIPTION, so the SUMMARY is just a truncated
///   prefix of it.
///
/// Only the first group becomes tasks. Title keywords are deliberately NOT
/// consulted: topic titles contain words like "post" (Postmodern), "exam"
/// (Examples), "fill" (Fulfilling), while real items like "Unit 3 Quote
/// Point Tracker" contain none.
bool looksLikeLearningSuiteAssignment(String subject, String? notes) {
  final title = subject.trim();
  // IcalService substitutes 'Untitled' for blank schedule lines.
  if (title.isEmpty || title == 'Untitled') return false;
  final body = (notes ?? '').trim();
  if (body.isEmpty) return true;
  // The iCal parser hands back SUMMARY raw but DESCRIPTION unescaped, so
  // normalize `\,` / `\n` escapes on both sides before comparing.
  // Whitespace is squashed too: iCal folding can drop the space at the
  // wrap point ("DDQuote Points"), breaking a naive prefix check.
  String normalize(String s) =>
      _squashWhitespace(_unescapeIcalText(s));
  final a = normalize(title);
  final b = normalize(body);
  if (b.startsWith(a) || a.startsWith(b)) return false;
  // SUMMARY truncates around ~70 chars; match the head as a fallback.
  if (a.length > 50 && b.startsWith(a.substring(0, 50))) return false;
  if (b.length > 50 && a.startsWith(b.substring(0, 50))) return false;
  return true;
}

/// Unescapes iCal TEXT values (`\,` -> `,`, `\n` -> newline, ...).
String _unescapeIcalText(String s) => s.replaceAllMapped(
      RegExp(r'\\(.)', dotAll: true),
      (m) => switch (m.group(1)) {
        'n' || 'N' => '\n',
        _ => m.group(1)!,
      },
    );

String _squashWhitespace(String s) => s.replaceAll(RegExp(r'\s+'), '');

bool _sameAssignees(List<TaskAssignee> a, List<TaskAssignee> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameTags(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Whether a feed event qualifies as a task (same rule [TaskCubit.importFromFeed]
/// uses to create shadow tasks). Extracted so [FeedCubit] can mark
/// [PlannerEvent.isTask] with the identical heuristic.
bool isTaskCandidate(PlannerEvent event, Feed feed, DateTime now) {
  final cutoff =
      now.subtract(const Duration(days: TaskCubit.importLookbackDays));
  // Windows open early: judge staleness by the due end, not the open start.
  if (event.end.isBefore(cutoff)) return false;
  if (feed.kind == FeedKind.canvas &&
      !(event.sourceUid?.startsWith('event-assignment-') ?? false)) {
    return false;
  }
  if (feed.kind == FeedKind.learningSuite &&
      !looksLikeLearningSuiteAssignment(event.subject, event.notes)) {
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
        : task.copyWith(done: true, completedAt: now, failed: false);
    updateTask(updated);
  }

  String? get activeTrackingId {
    for (final task in state) {
      if (task.isTracking) return task.id;
    }
    return null;
  }

  Task? get activeTrackingTask {
    final id = activeTrackingId;
    return id == null ? null : byId(id);
  }

  void startTracking(String taskId, {DateTime? now}) {
    final target = byId(taskId);
    if (target == null || target.done) return;
    final at = now ?? DateTime.now();
    if (target.isTracking) return;
    var next = state;
    final activeId = activeTrackingId;
    if (activeId != null && activeId != taskId) {
      final active = byId(activeId);
      if (active != null && active.timerStartedAt != null) {
        final start = active.timerStartedAt!;
        final end =
            at.isAfter(start) ? at : start.add(const Duration(seconds: 1));
        next = next
            .map((t) => t.id == activeId
                ? t.copyWith(
                    actualStart: start,
                    actualEnd: end,
                    clearTimerStartedAt: true,
                  )
                : t)
            .toList();
      }
    }
    next = next
        .map((t) => t.id == taskId
            ? t.copyWith(timerStartedAt: at, failed: false)
            : t)
        .toList();
    if (next != state) emitChange(next);
  }

  void stopTracking(String taskId, {DateTime? now}) {
    final task = byId(taskId);
    if (task == null || !task.isTracking) return;
    final at = now ?? DateTime.now();
    final start = task.timerStartedAt!;
    final end = at.isAfter(start) ? at : start.add(const Duration(seconds: 1));
    updateTask(
      task.copyWith(
        actualStart: start,
        actualEnd: end,
        clearTimerStartedAt: true,
      ),
    );
  }

  void cancelTracking(String taskId) {
    final task = byId(taskId);
    if (task == null || !task.isTracking) return;
    updateTask(task.copyWith(clearTimerStartedAt: true));
  }

  void clearReported(String taskId) {
    final task = byId(taskId);
    if (task == null) return;
    if (task.actualStart == null &&
        task.actualEnd == null &&
        !task.isTracking &&
        !task.failed) {
      return;
    }
    updateTask(
      task.copyWith(
        clearActualStart: true,
        clearActualEnd: true,
        clearTimerStartedAt: true,
        failed: false,
      ),
    );
  }

  void setFailed(String taskId, bool failed, {DateTime? now}) {
    final task = byId(taskId);
    if (task == null || task.failed == failed) return;
    if (failed && task.isTracking) {
      final at = now ?? DateTime.now();
      final start = task.timerStartedAt!;
      final end =
          at.isAfter(start) ? at : start.add(const Duration(seconds: 1));
      updateTask(
        task.copyWith(
          actualStart: start,
          actualEnd: end,
          clearTimerStartedAt: true,
          done: false,
          clearCompletedAt: true,
          failed: true,
        ),
      );
      return;
    }
    if (failed) {
      updateTask(
        task.copyWith(done: false, clearCompletedAt: true, failed: true),
      );
      return;
    }
    updateTask(task.copyWith(failed: false));
  }

  void setPlannedInterval(String taskId, DateTime start, DateTime end) {
    final task = byId(taskId);
    if (task == null) return;
    final normalizedEnd =
        end.isAfter(start) ? end : start.add(const Duration(hours: 1));
    updateTask(task.copyWith(plannedStart: start, plannedEnd: normalizedEnd));
  }

  void clearPlannedInterval(String taskId) {
    final task = byId(taskId);
    if (task == null || !task.hasPlanned) return;
    updateTask(
      task.copyWith(clearPlannedStart: true, clearPlannedEnd: true),
    );
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
            plannedStart: event.start,
            plannedEnd: event.end,
            failed: event.failed,
            assignees: event.assignees,
            tagIds: event.tagIds,
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
          plannedStart: event.start,
          plannedEnd: event.end,
          failed: event.failed,
          assignees: event.assignees,
          tagIds: event.tagIds,
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
      plannedStart: event.start,
      plannedEnd: event.end,
      failed: event.failed,
      assignees: event.assignees,
      tagIds: event.tagIds,
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
              (!done && completedAt == null)) &&
          (!done || !task.failed)) {
        continue;
      }
      updateTask(
        task.copyWith(
          done: done,
          completedAt: completedAt,
          clearCompletedAt: !done,
          failed: done ? false : task.failed,
        ),
      );
    }
  }

  void setFailedForEvent(String eventId, bool failed) {
    for (final task in tasksForEventId(eventId)) {
      if (task.failed == failed) continue;
      if (failed) {
        updateTask(
          task.copyWith(done: false, clearCompletedAt: true, failed: true),
        );
      } else {
        updateTask(task.copyWith(failed: false));
      }
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
            task.failed != event.failed ||
            task.completedAt != event.completedAt ||
            !_sameAssignees(task.assignees, event.assignees) ||
            !_sameTags(task.tagIds, event.tagIds)) {
          updateTask(
            task.copyWith(
              done: event.done,
              completedAt: event.completedAt,
              clearCompletedAt: !event.done,
              failed: event.failed,
              assignees: event.assignees,
              tagIds: event.tagIds,
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
      plannedStart: event.start,
      plannedEnd: event.end,
      failed: event.failed,
      assignees: event.assignees,
      tagIds: event.tagIds,
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
    final aDue = a.plannedStart ?? a.due;
    final bDue = b.plannedStart ?? b.due;
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
      // Drop previously imported open tasks that are schedule/commentary
      // so a resync cleans up topic clutter. Done tasks are kept to
      // preserve the user's completion history.
      base = base
          .where(
            (t) =>
                t.classId != feed.id ||
                !t.isImported ||
                t.done ||
                looksLikeLearningSuiteAssignment(t.title, t.notes),
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
      // Learning Suite open..due windows (DTSTART..DTEND) are due at the
      // end of the window: without this every window task would be due
      // (and instantly overdue) on its open date.
      final isWindow = feed.kind == FeedKind.learningSuite &&
          event.allDay &&
          event.end.difference(event.start) > const Duration(days: 1);
      imported.add(Task(
        id: event.id,
        title: event.subject,
        notes: event.notes,
        due: isWindow ? event.end : event.start,
        done: event.done,
        completedAt: event.completedAt,
        sourceEventId: event.id,
        classId: feed.id,
        classLabel: event.classLabel,
        plannedStart: event.start,
        plannedEnd: event.end,
        failed: event.failed,
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
    if (list == null) return null;
    final out = <Task>[];
    for (final item in list) {
      try {
        out.add(Task.fromJson(Map<String, dynamic>.from(item as Map)));
      } catch (_) {}
    }
    return out;
  }

  @override
  Map<String, dynamic> toJson(List<Task> state) =>
      {'tasks': state.map((t) => t.toJson()).toList()};
}
