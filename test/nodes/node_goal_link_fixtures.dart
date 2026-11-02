import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

Node goal(String id, {List<String> parents = const []}) => Node(
  id: id,
  title: id,
  parentIds: parents,
  createdAt: DateTime(2026, 9, 1),
);

PlannerEvent event(
  String id, {
  bool isTask = true,
  String recurrenceRule = '',
  String? seriesId,
  String? feedId,
  String? sourceUid,
  DateTime? start,
}) => PlannerEvent(
  id: id,
  subject: 'Event $id',
  start: start ?? DateTime(2026, 9, 12, 9),
  end: (start ?? DateTime(2026, 9, 12, 9)).add(const Duration(hours: 1)),
  recurrenceRule: recurrenceRule,
  seriesId: seriesId,
  feedId: feedId,
  sourceUid: sourceUid,
  isTask: isTask,
);

void installGoalLinkStorage() {
  final storage = MockStorage();
  when(() => storage.read(any())).thenReturn(null);
  when(() => storage.write(any(), any())).thenAnswer((_) async {});
  when(() => storage.delete(any())).thenAnswer((_) async {});
  when(() => storage.clear()).thenAnswer((_) async {});
  HydratedBloc.storage = storage;
}
