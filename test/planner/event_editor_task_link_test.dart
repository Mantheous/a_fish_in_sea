import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/event_editor_task_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  for (final done in [false, true]) {
    test(
      'editing work time preserves ${done ? "completed" : "running"} task state',
      () async {
        final nodes = NodeCubit();
        final calendar = CalendarCubit();
        addTearDown(nodes.close);
        addTearDown(calendar.close);
        final start = DateTime(2030, 1, 1, 14, 15);
        final end = DateTime(2030, 1, 1, 15, 45);
        final due = DateTime(2030, 1, 3, 17);
        final recordedEnd = DateTime(2029, 12, 31, 16);
        final sessions = [
          TimeSession(
            id: 'work',
            start: recordedEnd.subtract(const Duration(minutes: 20)),
            end: recordedEnd,
          ),
        ];
        final original = Node(
          id: 'assignment',
          title: 'Homework',
          createdAt: recordedEnd,
          sourceEventId: 'assignment',
          feedId: 'canvas',
          schedule: ScheduleFacet(
            due: due,
            start: due,
            end: due,
            isFixed: true,
          ),
          status: done ? NodeStatus.done : NodeStatus.open,
          completedAt: done ? recordedEnd : null,
          sessions: sessions,
          timerStartedAt: done ? null : recordedEnd,
        );
        nodes.addNode(original);
        final saved = PlannerEvent(
          id: 'assignment',
          subject: 'Homework',
          feedId: 'canvas',
          start: start,
          end: end,
          isTask: true,
          done: done,
          completedAt: original.completedAt,
        );
        calendar.addEvent(saved);

        syncEditorTaskLink(nodes, calendar, saved, syncFeedWorkTime: true);

        expect(
          nodes.byId(original.id),
          original.copyWith(
            schedule: original.schedule!.copyWith(start: start, end: end),
          ),
        );
        expect(nodes.state, hasLength(1));
      },
    );
  }
}
