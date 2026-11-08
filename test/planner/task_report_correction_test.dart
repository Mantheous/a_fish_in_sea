import 'dart:convert';

import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_sync.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  late NodeCubit nodes;
  late CalendarCubit calendar;
  late UndoCubit undo;
  final start = DateTime(2026, 10, 30, 9);
  final end = start.add(const Duration(minutes: 20));

  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    nodes = NodeCubit();
    calendar = CalendarCubit();
    undo = UndoCubit();
    addTearDown(nodes.close);
    addTearDown(calendar.close);
    addTearDown(undo.close);
  });

  test('Adjust preserves pre-promotion runs, identity, restore and undo', () {
    calendar.addEvent(
      PlannerEvent(id: 'event', subject: 'Study', start: start, end: end),
    );
    NodeEventLink.startEventTracking(nodes, calendar, 'event', now: start);
    NodeEventLink.stopEventTrackingAligned(nodes, calendar, 'event', now: end);
    final earlier = calendar.byId('event')!.recordedSessions.single;
    NodeEventLink.markEventAsNode(calendar, nodes, 'event');
    final taskId = calendar.byId('event')!.taskId!;
    expect(nodes.byId(taskId)!.recordedSessions, isEmpty);
    NodeEventLink.startNodeTracking(
      nodes,
      calendar,
      taskId,
      now: start.add(const Duration(hours: 2)),
    );
    NodeEventLink.stopNodeTrackingAligned(
      nodes,
      calendar,
      taskId,
      now: end.add(const Duration(hours: 2)),
    );
    final original = nodes.byId(taskId)!.recordedSessions.single;
    final corrected = original.copyWith(
      start: original.start.add(const Duration(minutes: 5)),
      end: original.end.add(const Duration(minutes: 10)),
    );
    final beforeNode = nodes.byId(taskId);
    final beforeEvent = calendar.byId('event');
    undo.resetHistory();

    expect(
      NodeEventSync.setNodeReported(
        nodes,
        calendar,
        taskId,
        corrected.start,
        corrected.end,
      ),
      isTrue,
    );
    expect(nodes.byId(taskId)!.recordedSessions, [corrected]);
    expect(calendar.byId('event')!.recordedSessions, [earlier, corrected]);
    expect(calendar.byId('event')!.actualStart, earlier.start);
    expect(calendar.byId('event')!.actualEnd, corrected.end);
    expect(
      calendar.byId('event')!.reportedDuration,
      earlier.duration + corrected.duration,
    );

    // Cross the actual JSON boundary, then reload both persisted stores.
    final restoredNodes = nodes.fromJson(
      jsonDecode(jsonEncode(nodes.toJson(nodes.state))),
    );
    final restoredEvents = calendar.fromJson(
      jsonDecode(jsonEncode(calendar.toJson(calendar.state))),
    );
    expect(restoredNodes!.single.recordedSessions, [corrected]);
    expect(restoredEvents!.single.recordedSessions, [earlier, corrected]);

    expect(undo.state.undoStack, hasLength(1));
    expect(undo.state.undoStack.single.entries, hasLength(2));
    undo.undo();
    expect(nodes.byId(taskId), beforeNode);
    expect(calendar.byId('event'), beforeEvent);
    undo.redo();
    expect(nodes.byId(taskId)!.recordedSessions, [corrected]);
    expect(calendar.byId('event')!.recordedSessions, [earlier, corrected]);
    expect(
      NodeEventSync.setNodeReported(
        nodes,
        calendar,
        taskId,
        corrected.start,
        corrected.end,
      ),
      isFalse,
    );
    expect(undo.state.undoStack, hasLength(1));
  });

  for (final legacy in [false, true]) {
    test('correction merges into every link (legacy: $legacy)', () {
      final original = TimeSession(
        id: TimeSession.idFor(start, end),
        start: start,
        end: end,
      );
      final independent = TimeSession(
        id: 'independent',
        start: end,
        end: end.add(const Duration(minutes: 10)),
      );
      nodes.addNode(
        Node(
          id: 'task',
          title: 'Study',
          createdAt: start,
          calendarEventId: 'direct',
          sourceEventId: 'source',
          sessions: legacy ? const [] : [original],
          actualStart: start,
          actualEnd: end,
          timerStartedAt: end,
        ),
      );
      for (final id in ['direct', 'source', 'reverse', 'unrelated']) {
        calendar.addEvent(
          PlannerEvent(
            id: id,
            subject: id,
            start: start,
            end: end,
            taskId: id == 'reverse' ? 'task' : null,
            sessions: legacy ? const [] : [original, independent],
            actualStart: start,
            actualEnd: end,
          ),
        );
      }
      final unrelated = calendar.byId('unrelated');
      // Invalid ranges still clamp to one minute, and manual saves stop timers.
      NodeEventSync.setNodeReported(nodes, calendar, 'task', end, start);
      final corrected = original.copyWith(
        start: end,
        end: end.add(const Duration(minutes: 1)),
      );
      expect(nodes.byId('task')!.recordedSessions, [corrected]);
      expect(nodes.byId('task')!.isTracking, isFalse);
      for (final id in ['direct', 'source', 'reverse']) {
        expect(
          calendar.byId(id)!.recordedSessions,
          unorderedEquals([corrected, if (!legacy) independent]),
        );
      }
      expect(calendar.byId('unrelated'), unrelated);
    });
  }

  test('manual entry preserves event-only runs when the task has no runs', () {
    nodes.addNode(Node(id: 'task', title: 'Study', createdAt: start));
    calendar.addEvent(
      PlannerEvent(
        id: 'event',
        subject: 'Study',
        start: start,
        end: end,
        taskId: 'task',
        actualStart: start,
        actualEnd: end,
      ),
    );
    final earlier = calendar.byId('event')!.recordedSessions.single;
    NodeEventSync.setNodeReported(
      nodes,
      calendar,
      'task',
      end,
      end.add(const Duration(minutes: 10)),
    );
    expect(calendar.byId('event')!.recordedSessions, [
      earlier,
      nodes.byId('task')!.recordedSessions.single,
    ]);
  });
}
