import 'package:bloc/bloc.dart';

import '../model/planner_event.dart';
import '../model/task.dart';

const String calendarDraftEventId = '__draft__';

PlannerEvent draftSeedFromTask(Task task, {DateTime? now}) {
  final ref = task.due ?? now ?? DateTime.now();
  final start = DateTime(ref.year, ref.month, ref.day, 9);
  return PlannerEvent(
    id: calendarDraftEventId,
    subject: task.title,
    notes: task.notes,
    start: start,
    end: start.add(const Duration(hours: 1)),
    classLabel: task.classLabel,
    taskId: task.id,
  );
}

class CalendarDraftCubit extends Cubit<PlannerEvent?> {
  CalendarDraftCubit() : super(null);

  void requestDraft(PlannerEvent seed) => emit(seed);

  PlannerEvent? takePending() {
    final pending = state;
    if (pending != null) emit(null);
    return pending;
  }

  void clear() => emit(null);
}
