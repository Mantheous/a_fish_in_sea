import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/calendar_report.dart';
import 'package:a_fish_in_sea/planner/service/report_adjustment.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

ReportBlock _block({
  required String displayId,
  required DateTime start,
  required DateTime end,
  ReportBlockKind kind = ReportBlockKind.accepted,
  String? eventId,
  String? entryId,
  String? sessionId,
}) => ReportBlock(
  displayId: displayId,
  title: 'Report',
  start: start,
  end: end,
  kind: kind,
  eventId: eventId,
  entryId: entryId,
  sessionId: sessionId,
  status: kind == ReportBlockKind.accepted ? ReportStatus.attended : null,
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

  group('applyReportedInterval', () {
    test('manual entries stay manual and move between day buckets', () {
      final reporting = ReportingCubit();
      final start = DateTime(2026, 9, 4, 23, 40);
      final end = DateTime(2026, 9, 5, 0, 10);
      reporting.upsertEntry(
        DateTime(2026, 9, 4),
        ReportedEntry(
          id: 'r1',
          title: 'Late study',
          start: start,
          end: start.add(const Duration(minutes: 20)),
          status: ReportStatus.attended,
          auto: false,
        ),
      );
      final reported = applyReportedInterval(
        reporting: reporting,
        calendar: CalendarCubit(),
        nodes: NodeCubit(),
        block: _block(
          displayId: 'report:r1',
          start: start,
          end: start.add(const Duration(minutes: 20)),
          entryId: 'r1',
        ),
        start: end,
        end: end.add(const Duration(minutes: 30)),
      );

      expect(reported, isTrue);
      expect(reporting.entriesForDay(DateTime(2026, 9, 4)), isEmpty);
      final moved = reporting.entriesForDay(DateTime(2026, 9, 5)).single;
      expect(moved.id, 'r1');
      expect(moved.start, end);
      expect(moved.end, end.add(const Duration(minutes: 30)));
      expect(moved.auto, isFalse);
    });

    test('timer blocks write the interval back to their event', () {
      final calendar = CalendarCubit();
      final start = DateTime(2026, 9, 4, 9, 10);
      final end = DateTime(2026, 9, 4, 9, 40);
      calendar.addEvent(
        PlannerEvent(
          id: 'e1',
          subject: 'Study',
          start: DateTime(2026, 9, 4, 9),
          end: DateTime(2026, 9, 4, 10),
          actualStart: start,
          actualEnd: end,
        ),
      );
      final newStart = DateTime(2026, 9, 4, 9, 20);
      final newEnd = DateTime(2026, 9, 4, 9, 55);

      final reported = applyReportedInterval(
        reporting: ReportingCubit(),
        calendar: calendar,
        nodes: NodeCubit(),
        block: _block(
          displayId: 'report:timer:e1',
          start: start,
          end: end,
          kind: ReportBlockKind.timer,
          eventId: 'e1',
        ),
        start: newStart,
        end: newEnd,
      );

      expect(reported, isTrue);
      final updated = calendar.byId('e1')!;
      expect(updated.actualStart, newStart);
      expect(updated.actualEnd, newEnd);
      expect(updated.start, DateTime(2026, 9, 4, 9));
    });

    test('node-only reports write the interval back to the node', () {
      final nodes = NodeCubit();
      final start = DateTime(2026, 9, 4, 9, 10);
      final end = DateTime(2026, 9, 4, 9, 40);
      nodes.addNode(
        Node(
          id: 'n1',
          title: 'Study',
          createdAt: DateTime(2026, 9, 4),
          actualStart: start,
          actualEnd: end,
        ),
      );
      final newStart = DateTime(2026, 9, 4, 9, 5);
      final newEnd = DateTime(2026, 9, 4, 9, 50);

      final reported = applyReportedInterval(
        reporting: ReportingCubit(),
        calendar: CalendarCubit(),
        nodes: nodes,
        block: _block(
          displayId: 'report:timer:n1',
          start: start,
          end: end,
          kind: ReportBlockKind.timer,
        ),
        start: newStart,
        end: newEnd,
      );

      expect(reported, isTrue);
      final updated = nodes.byId('n1')!;
      expect(updated.actualStart, newStart);
      expect(updated.actualEnd, newEnd);
    });

    test('a session block moves only its own run', () {
      final calendar = CalendarCubit();
      final first = TimeSession(
        id: 'ts:1',
        start: DateTime(2026, 9, 4, 9, 10),
        end: DateTime(2026, 9, 4, 9, 40),
      );
      final second = TimeSession(
        id: 'ts:2',
        start: DateTime(2026, 9, 4, 14),
        end: DateTime(2026, 9, 4, 14, 20),
      );
      calendar.addEvent(
        PlannerEvent(
          id: 'e1',
          subject: 'Study',
          start: DateTime(2026, 9, 4, 9),
          end: DateTime(2026, 9, 4, 15),
          sessions: [first, second],
          actualStart: first.start,
          actualEnd: second.end,
        ),
      );
      final newStart = DateTime(2026, 9, 4, 9, 20);
      final newEnd = DateTime(2026, 9, 4, 9, 55);
      final reported = applyReportedInterval(
        reporting: ReportingCubit(),
        calendar: calendar,
        nodes: NodeCubit(),
        block: _block(
          displayId: 'report:timer:e1#ts:1',
          start: first.start,
          end: first.end,
          kind: ReportBlockKind.timer,
          eventId: 'e1',
          sessionId: first.id,
        ),
        start: newStart,
        end: newEnd,
      );
      expect(reported, isTrue);
      final updated = calendar.byId('e1')!;
      expect(updated.sessions, hasLength(2));
      expect(updated.sessions.first.start, newStart);
      expect(updated.sessions.first.end, newEnd);
      expect(updated.sessions.last, second);
      expect(updated.reportedDuration, const Duration(minutes: 55));
    });

    test('deleting a session leaves the other runs alone', () {
      final calendar = CalendarCubit();
      final first = TimeSession(
        id: 'ts:1',
        start: DateTime(2026, 9, 4, 9, 10),
        end: DateTime(2026, 9, 4, 9, 40),
      );
      final second = TimeSession(
        id: 'ts:2',
        start: DateTime(2026, 9, 4, 14),
        end: DateTime(2026, 9, 4, 14, 20),
      );
      calendar.addEvent(
        PlannerEvent(
          id: 'e1',
          subject: 'Study',
          start: DateTime(2026, 9, 4, 9),
          end: DateTime(2026, 9, 4, 15),
          sessions: [first, second],
          actualStart: first.start,
          actualEnd: second.end,
        ),
      );
      final deleted = deleteReportedBlock(
        reporting: ReportingCubit(),
        calendar: calendar,
        nodes: NodeCubit(),
        block: _block(
          displayId: 'report:timer:e1#ts:2',
          start: second.start,
          end: second.end,
          kind: ReportBlockKind.timer,
          eventId: 'e1',
          sessionId: second.id,
        ),
      );
      expect(deleted, isTrue);
      final updated = calendar.byId('e1')!;
      expect(updated.sessions, [first]);
      expect(updated.actualStart, first.start);
      expect(updated.actualEnd, first.end);
      expect(updated.reportedDuration, const Duration(minutes: 30));
    });

    test('deleting a calendar-less node session keeps its siblings', () {
      final nodes = NodeCubit();
      final first = TimeSession(
        id: 'ts:1',
        start: DateTime(2026, 9, 4, 9, 10),
        end: DateTime(2026, 9, 4, 9, 40),
      );
      final second = TimeSession(
        id: 'ts:2',
        start: DateTime(2026, 9, 4, 14),
        end: DateTime(2026, 9, 4, 14, 20),
      );
      nodes.addNode(
        Node(
          id: 'n1',
          title: 'Study',
          createdAt: DateTime(2026, 9, 4),
          sessions: [first, second],
          actualStart: first.start,
          actualEnd: second.end,
        ),
      );
      final deleted = deleteReportedBlock(
        reporting: ReportingCubit(),
        calendar: CalendarCubit(),
        nodes: nodes,
        block: _block(
          displayId: 'report:timer:n1#ts:1',
          start: first.start,
          end: first.end,
          kind: ReportBlockKind.timer,
          sessionId: first.id,
        ),
      );
      expect(deleted, isTrue);
      expect(nodes.byId('n1')?.sessions, [second]);
      expect(nodes.byId('n1')?.reportedDuration, const Duration(minutes: 20));
    });

    test('deleting a manual entry removes it from its day', () {
      final reporting = ReportingCubit();
      final start = DateTime(2026, 9, 4, 23, 40);
      reporting.upsertEntry(
        DateTime(2026, 9, 4),
        ReportedEntry(
          id: 'r1',
          title: 'Late study',
          start: start,
          end: start.add(const Duration(minutes: 20)),
          status: ReportStatus.attended,
          auto: false,
        ),
      );
      final deleted = deleteReportedBlock(
        reporting: reporting,
        calendar: CalendarCubit(),
        nodes: NodeCubit(),
        block: _block(
          displayId: 'report:r1',
          start: start,
          end: start.add(const Duration(minutes: 20)),
          entryId: 'r1',
        ),
      );
      expect(deleted, isTrue);
      expect(reporting.entriesForDay(DateTime(2026, 9, 4)), isEmpty);
    });

    test('live reports are read-only', () {
      final calendar = CalendarCubit();
      final start = DateTime(2026, 9, 4, 9, 10);
      final end = DateTime(2026, 9, 4, 9, 40);
      calendar.addEvent(
        PlannerEvent(
          id: 'e1',
          subject: 'Study',
          start: start,
          end: end,
          actualStart: start,
          actualEnd: end,
        ),
      );

      final reported = applyReportedInterval(
        reporting: ReportingCubit(),
        calendar: calendar,
        nodes: NodeCubit(),
        block: _block(
          displayId: 'report:live:e1',
          start: start,
          end: end,
          kind: ReportBlockKind.live,
          eventId: 'e1',
        ),
        start: start.subtract(const Duration(minutes: 10)),
        end: end,
      );

      expect(reported, isFalse);
      expect(calendar.byId('e1')!.actualStart, start);
    });

    test('a non-positive range is floored to one minute', () {
      final reporting = ReportingCubit();
      final start = DateTime(2026, 9, 4, 9, 10);
      final end = DateTime(2026, 9, 4, 9, 40);
      reporting.upsertEntry(
        DateTime(2026, 9, 4),
        ReportedEntry(
          id: 'r1',
          title: 'Study',
          start: start,
          end: end,
          status: ReportStatus.attended,
          auto: false,
        ),
      );
      final newStart = DateTime(2026, 9, 4, 10);

      applyReportedInterval(
        reporting: reporting,
        calendar: CalendarCubit(),
        nodes: NodeCubit(),
        block: _block(
          displayId: 'report:r1',
          start: start,
          end: end,
          entryId: 'r1',
        ),
        start: newStart,
        end: newStart,
      );

      final updated = reporting.entriesForDay(DateTime(2026, 9, 4)).single;
      expect(updated.end, newStart.add(const Duration(minutes: 1)));
    });
  });
}
