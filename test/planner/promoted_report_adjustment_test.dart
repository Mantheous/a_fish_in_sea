import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_sync.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/calendar_report.dart';
import 'package:a_fish_in_sea/planner/service/report_adjustment.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  late CalendarCubit calendar;
  late NodeCubit nodes;
  late ReportingCubit reporting;
  final start = DateTime(2026, 10, 29, 9);
  final end = start.add(const Duration(minutes: 30));

  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    calendar = CalendarCubit();
    nodes = NodeCubit();
    reporting = ReportingCubit();
    calendar.addEvent(
      PlannerEvent(id: 'event', subject: 'Study', start: start, end: end),
    );
    calendar.startTracking('event', now: start);
    calendar.stopTracking('event', now: end);
    NodeEventLink.markEventAsNode(calendar, nodes, 'event');
    addTearDown(calendar.close);
    addTearDown(nodes.close);
    addTearDown(reporting.close);
  });

  ReportBlock block() => buildReportBlocks(
    visibleEvents: calendar.state,
    nodes: nodes.state,
    reportsByDay: reporting.state,
    now: end,
  ).firstWhere((b) => b.kind == ReportBlockKind.timer && b.start == start);

  bool apply(ReportBlock block, DateTime newStart, DateTime newEnd) =>
      applyReportedInterval(
        reporting: reporting,
        calendar: calendar,
        nodes: nodes,
        block: block,
        start: newStart,
        end: newEnd,
      );

  for (final owner in ['event', 'task', 'event with other task runs']) {
    test('promoted event edits the run owned by $owner', () {
      final backing = NodeEventLink.backingNodeFor(nodes, calendar, 'event')!;
      expect(backing.recordedSessions, isEmpty);
      final original = calendar.byId('event')!.recordedSessions.single;
      final taskRuns = owner == 'task'
          ? [original]
          : owner == 'event'
          ? <TimeSession>[]
          : [
              TimeSession(
                id: 'other',
                start: end,
                end: end.add(const Duration(hours: 1)),
              ),
            ];
      nodes.setSessions(backing.id, taskRuns);
      final newStart = start.add(const Duration(minutes: 5));
      final newEnd = end.add(const Duration(minutes: 15));
      expect(apply(block(), newStart, newEnd), isTrue);
      final shown = buildReportBlocks(
        visibleEvents: calendar.state,
        nodes: nodes.state,
        reportsByDay: reporting.state,
      ).firstWhere((b) => b.sessionId == original.id);
      expect(shown.start, newStart);
      expect(shown.end, newEnd);
      expect(shown.sessionId, original.id);
      final runs = nodes.byId(backing.id)!.recordedSessions;
      expect(
        runs,
        owner == 'task'
            ? [original.copyWith(start: newStart, end: newEnd)]
            : taskRuns,
      );
      expect(apply(shown, newStart, newEnd), isFalse);
    });
  }

  test(
    'missing session rejects the edit without mirroring or clearing a timer',
    () {
      final backing = NodeEventLink.backingNodeFor(nodes, calendar, 'event')!;
      final original = calendar.byId('event')!;
      calendar.startTracking('event', now: end);
      final before = calendar.byId('event');
      expect(
        NodeEventSync.setNodeSession(
          nodes,
          calendar,
          backing.id,
          original.recordedSessions.single.id,
          start,
          end,
        ),
        isFalse,
      );
      expect(calendar.byId('event'), before);
      final stale = ReportBlock(
        displayId: reportTimerDisplayIdFor('event'),
        title: 'Stale run',
        start: start,
        end: end,
        kind: ReportBlockKind.timer,
        eventId: 'event',
        sessionId: 'missing',
      );
      expect(apply(stale, start, end), isFalse);
      expect(calendar.byId('event'), before);
    },
  );
}
