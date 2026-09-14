import 'package:syncfusion_flutter_calendar/calendar.dart';

import '../../common/undo/revertable_hydrated_cubit.dart';
import '../model/planner_event.dart';

class CalendarCubit extends RevertableHydratedCubit<List<PlannerEvent>> {
  CalendarCubit() : super(const []);

  void addEvent(PlannerEvent event) => emitChange([...state, event]);

  void updateEvent(PlannerEvent event) => emitChange(
        state.map((e) => e.id == event.id ? event : e).toList(),
      );

  void deleteEvent(String eventId) =>
      emitChange(state.where((e) => e.id != eventId).toList());

  void toggleDone(String eventId) {
    final event = byId(eventId);
    if (event == null || !event.isTask) return;
    final now = DateTime.now();
    updateEvent(
      event.done
          ? event.copyWith(done: false, clearCompletedAt: true)
          : event.copyWith(done: true, completedAt: now),
    );
  }

  String? get activeTrackingId {
    for (final event in state) {
      if (event.isTracking) return event.id;
    }
    return null;
  }

  PlannerEvent? get activeTrackingEvent {
    final id = activeTrackingId;
    return id == null ? null : byId(id);
  }

  void startTracking(String eventId, {DateTime? now}) {
    final target = byId(eventId);
    if (target == null || target.allDay) return;
    final at = now ?? DateTime.now();
    if (target.isTracking) return;
    var next = state;
    final activeId = activeTrackingId;
    if (activeId != null && activeId != eventId) {
      final active = byId(activeId);
      if (active != null && active.timerStartedAt != null) {
        final start = active.timerStartedAt!;
        final end = at.isAfter(start) ? at : start.add(const Duration(seconds: 1));
        next = next
            .map((e) => e.id == activeId
                ? e.copyWith(
                    actualStart: start,
                    actualEnd: end,
                    clearTimerStartedAt: true,
                  )
                : e)
            .toList();
      }
    }
    next = next
        .map((e) => e.id == eventId
            ? e.copyWith(timerStartedAt: at, failed: false)
            : e)
        .toList();
    if (next != state) emitChange(next);
  }

  void stopTracking(String eventId, {DateTime? now}) {
    final event = byId(eventId);
    if (event == null || !event.isTracking) return;
    final at = now ?? DateTime.now();
    final start = event.timerStartedAt!;
    final end = at.isAfter(start) ? at : start.add(const Duration(seconds: 1));
    updateEvent(
      event.copyWith(
        actualStart: start,
        actualEnd: end,
        clearTimerStartedAt: true,
      ),
    );
  }

  void cancelTracking(String eventId) {
    final event = byId(eventId);
    if (event == null || !event.isTracking) return;
    updateEvent(event.copyWith(clearTimerStartedAt: true));
  }

  void clearReported(String eventId) {
    final event = byId(eventId);
    if (event == null) return;
    if (event.actualStart == null &&
        event.actualEnd == null &&
        !event.isTracking &&
        !event.failed) {
      return;
    }
    updateEvent(
      event.copyWith(
        clearActualStart: true,
        clearActualEnd: true,
        clearTimerStartedAt: true,
        failed: false,
      ),
    );
  }

  void setFailed(String eventId, bool failed, {DateTime? now}) {
    final event = byId(eventId);
    if (event == null || event.failed == failed) return;
    if (failed && event.isTracking) {
      final at = now ?? DateTime.now();
      final start = event.timerStartedAt!;
      final end = at.isAfter(start) ? at : start.add(const Duration(seconds: 1));
      updateEvent(
        event.copyWith(
          actualStart: start,
          actualEnd: end,
          clearTimerStartedAt: true,
          failed: true,
        ),
      );
      return;
    }
    updateEvent(event.copyWith(failed: failed));
  }

  void setTaskLink(String eventId, String taskId) {
    final event = byId(eventId);
    if (event == null) return;
    if (event.taskId == taskId && event.isTask) return;
    updateEvent(event.copyWith(isTask: true, taskId: taskId));
  }

  void clearTaskLink(String eventId) {
    final event = byId(eventId);
    if (event == null) return;
    if (!event.isTask && event.taskId == null && !event.done) return;
    updateEvent(
      event.copyWith(
        isTask: false,
        clearTaskId: true,
        done: false,
        clearCompletedAt: true,
      ),
    );
  }

  PlannerEvent? byId(String eventId) {
    for (final event in state) {
      if (event.id == eventId) return event;
    }
    return null;
  }

  void replaceFeedEvents(String feedId, List<PlannerEvent> events) {
    final kept = state.where((e) => e.feedId != feedId).toList();
    emit([...kept, ...events]);
  }

  void removeFeedEvents(String feedId) {
    emit(state.where((e) => e.feedId != feedId).toList());
  }

  List<DateTime> occurrencesOf(
    PlannerEvent event,
    DateTime windowStart,
    DateTime windowEnd,
  ) {
    if (event.recurrenceRule.isEmpty) {
      final start = event.start;
      if (start.isBefore(windowStart) || start.isAfter(windowEnd)) {
        return const [];
      }
      return [start];
    }
    return SfCalendar.getRecurrenceDateTimeCollection(
      event.recurrenceRule,
      event.start,
      specificStartDate: windowStart,
      specificEndDate: windowEnd,
    );
  }

  List<PlannerEvent> eventsOnDay(DateTime day) {
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final result = <PlannerEvent>[];
    for (final event in state) {
      final occurrences = occurrencesOf(event, dayStart, dayEnd);
      if (occurrences.isNotEmpty) result.add(event);
    }
    result.sort((a, b) => a.start.compareTo(b.start));
    return result;
  }

  List<PlannerEvent> feedEventsInRange(
    DateTime windowStart,
    DateTime windowEnd,
  ) {
    final result = <PlannerEvent>[];
    for (final event in state) {
      if (event.feedId == null) continue;
      final occurrences = occurrencesOf(event, windowStart, windowEnd);
      if (occurrences.isNotEmpty) result.add(event);
    }
    result.sort((a, b) => a.start.compareTo(b.start));
    return result;
  }

  @override
  List<PlannerEvent>? fromJson(Map<String, dynamic> json) {
    final list = json['events'] as List<dynamic>?;
    if (list == null) return null;
    final out = <PlannerEvent>[];
    for (final item in list) {
      try {
        out.add(PlannerEvent.fromJson(Map<String, dynamic>.from(item as Map)));
      } catch (_) {}
    }
    return out;
  }

  @override
  Map<String, dynamic> toJson(List<PlannerEvent> state) =>
      {'events': state.map((e) => e.toJson()).toList()};
}
