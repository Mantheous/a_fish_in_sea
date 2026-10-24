import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_sync.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/calendar_report.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

PlannerEvent evt(String id,
        {String? taskId, bool isTask = true, bool done = false}) =>
    PlannerEvent(
      id: id,
      subject: 'Scripture study',
      start: DateTime(2026, 10, 13, 7),
      end: DateTime(2026, 10, 13, 7, 30),
      isTask: isTask,
      done: done,
      taskId: taskId,
    );

Node taskNode(String id,
        {String? calendarEventId, String? sourceEventId}) =>
    Node(
      id: id,
      title: 'Scripture study',
      createdAt: DateTime(2026, 10, 1),
      calendarEventId: calendarEventId,
      sourceEventId: sourceEventId,
    );

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  group('stop-tracking Mark complete sticks', () {
    test('standalone node stays done', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      nodes.addNode(taskNode('n1'));
      nodes.startTracking('n1', now: DateTime(2026, 10, 13, 7));
      nodes.stopTracking('n1', now: DateTime(2026, 10, 13, 7, 25));
      NodeEventLink.toggleNodeDone(nodes, calendar, 'n1');
      expect(nodes.byId('n1')?.isDone, isTrue);
      expect(nodes.byId('n1')?.hasReported, isTrue);
    });

    test('taskId-only link mirrors node -> event', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(evt('e1', taskId: 'n1'));
      nodes.addNode(taskNode('n1'));
      NodeEventLink.toggleNodeDone(nodes, calendar, 'n1');
      expect(nodes.byId('n1')?.isDone, isTrue);
      expect(calendar.byId('e1')?.done, isTrue);
    });

    test('taskId-only link mirrors event -> node', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(evt('e1', taskId: 'n1'));
      nodes.addNode(taskNode('n1'));
      NodeEventLink.toggleEventDone(calendar, nodes, 'e1');
      expect(calendar.byId('e1')?.done, isTrue);
      expect(nodes.byId('n1')?.isDone, isTrue);
    });

    test('a later calendar save cannot re-open the completed node', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(evt('e1', taskId: 'n1'));
      nodes.addNode(taskNode('n1'));
      // Stop + Mark complete.
      nodes.startTracking('n1', now: DateTime(2026, 10, 13, 7));
      NodeEventLink.stopNodeTrackingAligned(
          nodes, calendar, 'n1',
          now: DateTime(2026, 10, 13, 7, 25));
      NodeEventLink.toggleNodeDone(nodes, calendar, 'n1');
      expect(nodes.byId('n1')?.isDone, isTrue);
      // The next calendar save re-syncs the linked node (title/time only).
      nodes.upsertLinkedNodeForEvent(calendar.byId('e1')!);
      nodes.setDoneForEvent(
        'e1',
        done: calendar.byId('e1')!.done,
        completedAt: calendar.byId('e1')!.completedAt,
        taskId: calendar.byId('e1')!.taskId,
      );
      expect(nodes.byId('n1')?.isDone, isTrue,
          reason: 'done node must survive a re-sync of its event');
    });

    test('reapplying a saved done flag is idempotent', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(evt('e1', taskId: 'n1', done: true));
      nodes.addNode(taskNode('n1'));
      final completedAt = DateTime(2026, 10, 13, 7, 25);
      calendar.updateEvent(calendar.byId('e1')!.copyWith(
        completedAt: completedAt,
      ));

      NodeEventSync.setEventDone(calendar, nodes, 'e1', done: true);

      expect(calendar.byId('e1')?.done, isTrue);
      expect(calendar.byId('e1')?.completedAt, completedAt);
      expect(nodes.byId('n1')?.isDone, isTrue);
    });

    test('unchecking a saved task re-opens its node', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      final completedAt = DateTime(2026, 10, 13, 7, 25);
      calendar.addEvent(
          evt('e1', taskId: 'n1', done: true).copyWith(
        completedAt: completedAt,
      ));
      nodes.addNode(taskNode('n1').copyWith(
        status: NodeStatus.done,
        completedAt: completedAt,
      ));

      // Editor saved with Completed off after a Google push + re-sync:
      // the post-sync path must propagate the un-check, not just checks.
      NodeEventSync.setEventDone(calendar, nodes, 'e1', done: false);

      expect(calendar.byId('e1')?.done, isFalse);
      expect(calendar.byId('e1')?.completedAt, isNull);
      expect(nodes.byId('n1')?.isDone, isFalse);
      expect(nodes.byId('n1')?.completedAt, isNull);
    });
  });

  group('linked event/node persistence', () {
    test('reschedule moves personal task due date with its event', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      final due = DateTime(2026, 10, 14);
      final original = evt('e1', taskId: 'n1');
      calendar.addEvent(original);
      nodes.addNode(taskNode('n1', calendarEventId: 'e1').copyWith(
        schedule: ScheduleFacet(
          due: due,
          start: original.start,
          end: original.end,
          isFixed: true,
        ),
      ));
      final moved = original.copyWith(
        start: DateTime(2026, 10, 15, 8),
        end: DateTime(2026, 10, 15, 8, 45),
      );

      NodeEventSync.rescheduleLinkedEvent(calendar, nodes, moved);

      final schedule = nodes.byId('n1')!.schedule!;
      expect(calendar.byId('e1')?.start, moved.start);
      expect(schedule.start, moved.start);
      expect(schedule.end, moved.end);
      expect(schedule.due, moved.start);
      expect(schedule.isFixed, isTrue);
    });

    test('reschedule keeps imported assignment due date', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      final due = DateTime(2026, 10, 14);
      final original = evt('e1', taskId: 'n1');
      calendar.addEvent(original);
      nodes.addNode(taskNode('n1', sourceEventId: 'e1').copyWith(
        schedule: ScheduleFacet(
          due: due,
          start: original.start,
          end: original.end,
        ),
      ));
      final moved = original.copyWith(
        start: DateTime(2026, 10, 15, 8),
        end: DateTime(2026, 10, 15, 8, 45),
      );

      NodeEventSync.rescheduleLinkedEvent(calendar, nodes, moved);

      final schedule = nodes.byId('n1')!.schedule!;
      expect(schedule.start, moved.start);
      expect(schedule.end, moved.end);
      expect(schedule.due, due);
    });

    test('manual report edits and clears mirror to linked events', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      final event = evt('e1', taskId: 'n1');
      calendar.addEvent(event.copyWith(
        actualStart: DateTime(2026, 10, 13, 7),
        actualEnd: DateTime(2026, 10, 13, 7, 30),
      ));
      nodes.addNode(taskNode('n1', calendarEventId: 'e1').copyWith(
        actualStart: DateTime(2026, 10, 13, 7),
        actualEnd: DateTime(2026, 10, 13, 7, 30),
      ));

      NodeEventSync.setNodeReported(
        nodes,
        calendar,
        'n1',
        DateTime(2026, 10, 13, 8),
        DateTime(2026, 10, 13, 8, 30),
      );
      expect(calendar.byId('e1')?.actualStart, DateTime(2026, 10, 13, 8));

      NodeEventSync.clearNodeReported(nodes, calendar, 'n1');
      expect(nodes.byId('n1')?.hasReported, isFalse);
      expect(calendar.byId('e1')?.hasReported, isFalse);
      expect(
        buildReportBlocks(
          visibleEvents: [calendar.byId('e1')!],
          nodes: nodes.state,
          reportsByDay: const {},
        ),
        isEmpty,
      );
    });
  });

  group('single tracking path', () {
    test('stopping the node settles a running linked event timer', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(evt('e1', taskId: 'n1'));
      nodes.addNode(taskNode('n1', calendarEventId: 'e1'));
      nodes.startTracking('n1', now: DateTime(2026, 10, 13, 7));
      calendar.startTracking('e1', now: DateTime(2026, 10, 13, 7, 1));
      NodeEventLink.stopNodeTrackingAligned(nodes, calendar, 'n1',
          now: DateTime(2026, 10, 13, 7, 25));
      expect(nodes.byId('n1')?.isTracking, isFalse);
      expect(calendar.byId('e1')?.isTracking, isFalse);
      expect(nodes.byId('n1')?.hasReported, isTrue);
      expect(calendar.byId('e1')?.actualStart,
          nodes.byId('n1')?.actualStart);
      expect(calendar.byId('e1')?.actualEnd, nodes.byId('n1')?.actualEnd);
    });

    test('starting a node stops a running plain event timer', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(evt('plain', isTask: false));
      nodes.addNode(taskNode('n1'));
      calendar.startTracking('plain', now: DateTime(2026, 10, 13, 7));
      NodeEventLink.startNodeTracking(nodes, calendar, 'n1',
          now: DateTime(2026, 10, 13, 7, 10));
      expect(nodes.byId('n1')?.isTracking, isTrue);
      expect(calendar.byId('plain')?.isTracking, isFalse);
      expect(calendar.byId('plain')?.hasReported, isTrue);
    });

    test('event start delegates to the backing node for tasks', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(evt('e1', taskId: 'n1'));
      nodes.addNode(taskNode('n1', calendarEventId: 'e1'));
      NodeEventLink.startEventTracking(nodes, calendar, 'e1',
          now: DateTime(2026, 10, 13, 7));
      expect(nodes.byId('n1')?.isTracking, isTrue);
      expect(calendar.byId('e1')?.isTracking, isFalse);
    });

    test('completed task starts only when extra recording is allowed', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(evt('e1', taskId: 'n1'));
      nodes.addNode(taskNode('n1', calendarEventId: 'e1'));
      NodeEventLink.toggleNodeDone(nodes, calendar, 'n1');
      expect(nodes.byId('n1')?.isDone, isTrue);

      NodeEventLink.startEventTracking(nodes, calendar, 'e1',
          now: DateTime(2026, 10, 13, 8));
      expect(nodes.byId('n1')?.isTracking, isFalse,
          reason: 'the regular Start button stays disabled once done');

      NodeEventLink.startEventTracking(nodes, calendar, 'e1',
          now: DateTime(2026, 10, 13, 8, 5), allowCompleted: true);
      expect(nodes.byId('n1')?.isTracking, isTrue,
          reason: 'a report play records extra time on the finished task');
      expect(nodes.byId('n1')?.isDone, isTrue,
          reason: 'recording extra time must not reopen the task');
    });

    test('plain events still record on the event', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(evt('plain', isTask: false));
      nodes.addNode(taskNode('n1'));
      NodeEventLink.startEventTracking(nodes, calendar, 'plain',
          now: DateTime(2026, 10, 13, 7));
      expect(calendar.byId('plain')?.isTracking, isTrue);
      expect(nodes.byId('n1')?.isTracking, isFalse);
      NodeEventLink.stopEventTrackingAligned(nodes, calendar, 'plain',
          now: DateTime(2026, 10, 13, 7, 20));
      expect(calendar.byId('plain')?.hasReported, isTrue);
    });
  });

  group('node -> event completion mirror heals plain linked events', () {
    test('calendarEventId link mirrors even when the block is plain', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      // "Add to calendar" block saved as a plain event: the Task switch
      // describes the event, so the link survives with isTask off.
      calendar.addEvent(evt('e1', taskId: 'n1', isTask: false));
      nodes.addNode(taskNode('n1', calendarEventId: 'e1'));
      NodeEventLink.toggleNodeDone(nodes, calendar, 'n1');
      expect(nodes.byId('n1')?.isDone, isTrue);
      expect(calendar.byId('e1')?.done, isTrue);
      expect(calendar.byId('e1')?.isTask, isTrue);
    });

    test('sourceEventId homework link mirrors even when plain', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(evt('hw', isTask: false));
      nodes.addNode(taskNode('n1', sourceEventId: 'hw'));
      NodeEventLink.toggleNodeDone(nodes, calendar, 'n1');
      expect(nodes.byId('n1')?.isDone, isTrue);
      expect(calendar.byId('hw')?.done, isTrue);
      expect(calendar.byId('hw')?.isTask, isTrue);
    });

    test('taskId-only reverse link mirrors even when plain', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(evt('e1', taskId: 'n1', isTask: false));
      nodes.addNode(taskNode('n1'));
      NodeEventLink.toggleNodeDone(nodes, calendar, 'n1');
      expect(calendar.byId('e1')?.done, isTrue);
      expect(calendar.byId('e1')?.isTask, isTrue);
    });

    test('un-toggling re-opens the healed event', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(evt('e1', taskId: 'n1', isTask: false));
      nodes.addNode(taskNode('n1', calendarEventId: 'e1'));
      NodeEventLink.toggleNodeDone(nodes, calendar, 'n1');
      NodeEventLink.toggleNodeDone(nodes, calendar, 'n1');
      expect(nodes.byId('n1')?.isDone, isFalse);
      expect(calendar.byId('e1')?.done, isFalse);
    });

    test('setNodesDone mirrors onto plain linked events', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(evt('e1', taskId: 'n1', isTask: false));
      nodes.addNode(taskNode('n1', calendarEventId: 'e1'));
      final changed = NodeEventLink.setNodesDone(
        nodes,
        calendar,
        {'n1'},
        done: true,
      );
      expect(changed, 1);
      expect(calendar.byId('e1')?.done, isTrue);
      expect(calendar.byId('e1')?.isTask, isTrue);
    });

    test('unlinked plain events are left alone', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(evt('plain', isTask: false));
      nodes.addNode(taskNode('n1'));
      NodeEventLink.toggleNodeDone(nodes, calendar, 'n1');
      expect(calendar.byId('plain')?.done, isFalse);
      expect(calendar.byId('plain')?.isTask, isFalse);
    });
  });
}
