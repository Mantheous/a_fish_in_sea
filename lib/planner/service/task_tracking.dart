import 'package:equatable/equatable.dart';

import '../model/task.dart';

class TaskTrackingSelection extends Equatable {
  final Task? recording;
  final List<Task> current;
  final List<Task> previous;
  final List<Task> next;
  final List<Task> unscheduled;

  const TaskTrackingSelection({
    this.recording,
    this.current = const [],
    this.next = const [],
    this.previous = const [],
    this.unscheduled = const [],
  });

  bool get isEmpty =>
      recording == null &&
      current.isEmpty &&
      previous.isEmpty &&
      next.isEmpty &&
      unscheduled.isEmpty;

  @override
  List<Object?> get props => [recording, current, previous, next, unscheduled];
}

TaskTrackingSelection selectTaskTracking(
  List<Task> tasks,
  DateTime now, {
  int previousCount = 1,
  int nextCount = 2,
  int unscheduledCount = 3,
}) {
  final open = tasks.where((t) => !t.done).toList();
  Task? recording;
  for (final t in open) {
    if (t.isTracking) {
      recording = t;
      break;
    }
  }
  final recordingId = recording?.id;
  final scheduled = open
      .where((t) =>
          t.hasPlanned &&
          t.plannedStart != null &&
          t.plannedEnd != null &&
          t.id != recordingId)
      .toList();
  final current = scheduled
      .where((t) =>
          !t.plannedStart!.isAfter(now) && t.plannedEnd!.isAfter(now))
      .toList()
    ..sort((a, b) => a.plannedStart!.compareTo(b.plannedStart!));
  final currentIds = {for (final t in current) t.id};
  final ended = scheduled
      .where((t) => !t.plannedEnd!.isAfter(now) && !currentIds.contains(t.id))
      .toList()
    ..sort((a, b) => b.plannedEnd!.compareTo(a.plannedEnd!));
  final upcoming = scheduled
      .where((t) => t.plannedStart!.isAfter(now) && !currentIds.contains(t.id))
      .toList()
    ..sort((a, b) => a.plannedStart!.compareTo(b.plannedStart!));
  final unscheduled = open
      .where((t) => !t.hasPlanned && t.id != recordingId)
      .toList()
    ..sort(_byDueThenTitle);
  return TaskTrackingSelection(
    recording: recording,
    current: current,
    previous: ended.take(previousCount).toList().reversed.toList(),
    next: upcoming.take(nextCount).toList(),
    unscheduled: unscheduled.take(unscheduledCount).toList(),
  );
}

int _byDueThenTitle(Task a, Task b) {
  final aDue = a.plannedStart ?? a.due;
  final bDue = b.plannedStart ?? b.due;
  if (aDue == null && bDue == null) {
    return a.title.toLowerCase().compareTo(b.title.toLowerCase());
  }
  if (aDue == null) return 1;
  if (bDue == null) return -1;
  final cmp = aDue.compareTo(bDue);
  if (cmp != 0) return cmp;
  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
}
