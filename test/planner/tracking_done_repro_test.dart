import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
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

Node taskNode(String id, {String? calendarEventId}) => Node(
      id: id,
      title: 'Scripture study',
      createdAt: DateTime(2026, 10, 1),
      calendarEventId: calendarEventId,
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
}
