import 'package:bloc/bloc.dart';

import '../../nodes/model/node.dart';
import '../model/planner_event.dart';

const String calendarDraftEventId = '__draft__';

PlannerEvent draftSeedFromNode(Node node, {DateTime? now}) {
  final ref = node.schedule?.due ?? node.schedule?.start ?? now ?? DateTime.now();
  final start = DateTime(ref.year, ref.month, ref.day, 9);
  return PlannerEvent(
    id: calendarDraftEventId,
    subject: node.title,
    notes: node.notes,
    start: start,
    end: start.add(const Duration(hours: 1)),
    classLabel: node.classLabel,
    taskId: node.id,
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
