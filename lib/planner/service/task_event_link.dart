import '../bloc/calendar_cubit.dart';
import '../bloc/task_cubit.dart';

/// Coordinates the two-way link between task-events ([PlannerEvent.isTask])
/// and their backing [Task] objects so completion stays in sync whichever
/// side is toggled.
///
/// Backing-task shapes (see [TaskCubit]):
/// - personal events → linked task (`calendarEventId`, id `task:<eventId>`,
///   event `taskId` points back);
/// - feed events → imported-style shadow (`sourceEventId`, id == event id).
class TaskEventLink {
  const TaskEventLink._();

  /// Toggles an event's completion and mirrors it onto backing tasks.
  static void toggleEventDone(
    CalendarCubit calendar,
    TaskCubit tasks,
    String eventId,
  ) {
    final event = calendar.byId(eventId);
    if (event == null || !event.isTask) return;
    calendar.toggleDone(eventId);
    final updated = calendar.byId(eventId);
    if (updated == null) return;
    tasks.setDoneForEvent(
      eventId,
      done: updated.done,
      completedAt: updated.completedAt,
    );
  }

  /// Toggles a task's completion and mirrors it onto its event, if any.
  static void toggleTaskDone(
    TaskCubit tasks,
    CalendarCubit calendar,
    String taskId,
  ) {
    final task = tasks.byId(taskId);
    if (task == null) return;
    tasks.toggleDone(taskId);
    final updated = tasks.byId(taskId);
    if (updated == null) return;
    final eventId =
        updated.calendarEventId ?? updated.sourceEventId;
    if (eventId == null) return;
    final event = calendar.byId(eventId);
    if (event == null || !event.isTask) return;
    if (event.done == updated.done &&
        event.completedAt == updated.completedAt) {
      return;
    }
    calendar.updateEvent(
      event.copyWith(
        done: updated.done,
        completedAt: updated.completedAt,
        clearCompletedAt: !updated.done,
      ),
    );
  }

  /// Marks an event as a task, creating its backing task.
  static void markEventAsTask(
    CalendarCubit calendar,
    TaskCubit tasks,
    String eventId,
  ) {
    final event = calendar.byId(eventId);
    if (event == null || event.isTask) return;
    if (event.isFromFeed) {
      calendar.updateEvent(event.copyWith(isTask: true));
      final marked = calendar.byId(eventId) ?? event;
      tasks.ensureShadowForFeedEvent(marked.copyWith(isTask: true));
      return;
    }
    final taskId = tasks.upsertLinkedTaskForEvent(
      event.copyWith(isTask: true),
    );
    calendar.setTaskLink(eventId, taskId);
  }

  /// Un-marks an event as a task. The event is kept; backing tasks are
  /// deleted (user decision: uncheck means "not a task anymore").
  static void unmarkEventAsTask(
    CalendarCubit calendar,
    TaskCubit tasks,
    String eventId,
  ) {
    final event = calendar.byId(eventId);
    if (event == null || !event.isTask) return;
    tasks.removeTasksForEvent(eventId);
    calendar.clearTaskLink(eventId);
  }

  /// Pushes an event's title/notes/time into its personal linked task.
  /// Imported homework shadows keep their originally imported values.
  static void syncEventEditToTask(
    TaskCubit tasks,
    CalendarCubit calendar,
    String eventId,
  ) {
    final event = calendar.byId(eventId);
    if (event == null || !event.isTask || event.isFromFeed) return;
    tasks.upsertLinkedTaskForEvent(event);
  }

  /// Deletes an event together with its backing tasks.
  static void deleteEventAndTasks(
    CalendarCubit calendar,
    TaskCubit tasks,
    String eventId,
  ) {
    tasks.removeTasksForEvent(eventId);
    calendar.deleteEvent(eventId);
  }
}
