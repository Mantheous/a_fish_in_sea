import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/active_recording.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

Node taskNode(String id, {String? calendarEventId}) => Node(
  id: id,
  title: 'Scripture study',
  createdAt: DateTime(2026, 10, 1),
  calendarEventId: calendarEventId,
);

PlannerEvent event(String id, {String? taskId, bool isTask = true}) =>
    PlannerEvent(
      id: id,
      subject: 'Deep work',
      start: DateTime(2026, 10, 13, 7),
      end: DateTime(2026, 10, 13, 8),
      taskId: taskId,
      isTask: isTask,
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

  group('activeRecordingOf', () {
    test('finds a goal recording started from the Goals page', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      nodes.addNode(taskNode('n1'));
      nodes.startTracking('n1', now: DateTime(2026, 10, 13, 7));

      final active = activeRecordingOf(nodes.state, calendar.state);

      expect(active, isNotNull);
      expect(active!.nodeId, 'n1');
      expect(active.eventId, isNull);
      expect(active.title, 'Scripture study');
      expect(active.startedAt, DateTime(2026, 10, 13, 7));
    });

    test('finds a plain-event recording on the calendar store', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(event('plain', isTask: false));
      calendar.startTracking('plain', now: DateTime(2026, 10, 13, 7));

      final active = activeRecordingOf(nodes.state, calendar.state);

      expect(active?.eventId, 'plain');
      expect(active?.nodeId, isNull);
      expect(active?.title, 'Deep work');
    });

    test('returns null when nothing is recording', () {
      expect(activeRecordingOf(const [], const []), isNull);
    });
  });

  group('stopActiveRecording', () {
    test('stops a node recording and mirrors the session to its event', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(event('e1', taskId: 'n1'));
      nodes.addNode(taskNode('n1', calendarEventId: 'e1'));
      nodes.startTracking('n1', now: DateTime(2026, 10, 13, 7));
      final active = activeRecordingOf(nodes.state, calendar.state)!;

      stopActiveRecording(
        nodes,
        calendar,
        active,
        now: DateTime(2026, 10, 13, 7, 20),
      );

      expect(nodes.byId('n1')?.isTracking, isFalse);
      expect(nodes.byId('n1')?.reportedDuration, const Duration(minutes: 20));
      expect(calendar.byId('e1')?.isTracking, isFalse);
      expect(
        calendar.byId('e1')?.reportedDuration,
        const Duration(minutes: 20),
      );
    });

    test('stops a plain-event recording', () {
      final nodes = NodeCubit();
      final calendar = CalendarCubit();
      calendar.addEvent(event('plain', isTask: false));
      calendar.startTracking('plain', now: DateTime(2026, 10, 13, 7));
      final active = activeRecordingOf(nodes.state, calendar.state)!;

      stopActiveRecording(
        nodes,
        calendar,
        active,
        now: DateTime(2026, 10, 13, 7, 15),
      );

      expect(calendar.byId('plain')?.isTracking, isFalse);
      expect(
        calendar.byId('plain')?.reportedDuration,
        const Duration(minutes: 15),
      );
    });
  });
}
