// Regression coverage for the audit finding: a manual report linked to an
// all-day event is saved but never rendered in the Plan + Report lane.
import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/calendar_report.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:flutter_test/flutter_test.dart';

PlannerEvent allDayEvent({String id = 'e1', String? taskId}) => PlannerEvent(
  id: id,
  subject: 'All day $id',
  start: DateTime(2026, 9, 8),
  end: DateTime(2026, 9, 9),
  allDay: true,
  taskId: taskId,
);

void main() {
  group('audit: manual reports on all-day events', () {
    test('a saved manual report is shown at its seeded 09:00-10:00 time', () {
      final event = allDayEvent();
      final entry = buildManualReportForEvent(event);
      final blocks = buildReportBlocks(
        visibleEvents: [event],
        nodes: const [],
        reportsByDay: {
          '2026-09-08': [entry],
        },
        now: DateTime(2026, 9, 8, 12),
      );

      expect(blocks, hasLength(1));
      final block = blocks.single;
      expect(block.kind, ReportBlockKind.accepted);
      expect(block.eventId, 'e1');
      expect(block.entryId, entry.id);
      expect(block.start, DateTime(2026, 9, 8, 9));
      expect(block.end, DateTime(2026, 9, 8, 10));
      expect(isReportDisplayId(block.displayId), isTrue);
      // No timed block is fabricated out of the all-day plan row itself.
      expect(blocks.where((b) => b.kind != ReportBlockKind.accepted), isEmpty);
    });

    test('a manually edited interval is preserved', () {
      final entry = buildManualReportForEvent(allDayEvent()).copyWith(
        start: DateTime(2026, 9, 8, 13, 15),
        end: DateTime(2026, 9, 8, 14),
      );
      final blocks = buildReportBlocks(
        visibleEvents: [allDayEvent()],
        nodes: const [],
        reportsByDay: {
          '2026-09-08': [entry],
        },
      );

      expect(blocks, hasLength(1));
      expect(blocks.single.kind, ReportBlockKind.accepted);
      expect(blocks.single.start, DateTime(2026, 9, 8, 13, 15));
      expect(blocks.single.end, DateTime(2026, 9, 8, 14));
    });

    test('invalid all-day report intervals still render one hour', () {
      final entry = buildManualReportForEvent(
        allDayEvent(),
      ).copyWith(start: DateTime(2026, 9, 8, 9), end: DateTime(2026, 9, 8, 9));
      final blocks = buildReportBlocks(
        visibleEvents: [allDayEvent()],
        nodes: const [],
        reportsByDay: {
          '2026-09-08': [entry],
        },
      );

      expect(blocks, hasLength(1));
      expect(blocks.single.end, DateTime(2026, 9, 8, 10));
    });

    test('a repeated all-day event emits one accepted block', () {
      final event = allDayEvent();
      final entry = buildManualReportForEvent(event);
      final blocks = buildReportBlocks(
        visibleEvents: [event, event],
        nodes: const [],
        reportsByDay: {
          '2026-09-08': [entry],
        },
        now: DateTime(2026, 9, 8, 12),
      );

      expect(blocks, hasLength(1));
      expect(
        blocks.single.displayId,
        reportAcceptedDisplayIdFor('2026-09-08', entry.id),
      );
    });

    test('a repeated accepted entry in one bucket emits one block', () {
      final event = allDayEvent();
      final entry = buildManualReportForEvent(event);
      final blocks = buildReportBlocks(
        visibleEvents: [event],
        nodes: const [],
        reportsByDay: {
          '2026-09-08': [entry, entry],
        },
      );

      expect(blocks, hasLength(1));
      expect(blocks.single.entryId, entry.id);
    });

    test('distinct manual entry ids on one all-day event are all kept', () {
      final event = allDayEvent();
      final first = buildManualReportForEvent(event);
      final second = ReportedEntry(
        id: 'rep:e1:second',
        eventId: 'e1',
        title: event.subject,
        start: DateTime(2026, 9, 8, 15),
        end: DateTime(2026, 9, 8, 16),
        status: ReportStatus.attended,
        auto: false,
      );
      final blocks = buildReportBlocks(
        visibleEvents: [event],
        nodes: const [],
        reportsByDay: {
          '2026-09-08': [first, second],
        },
      );

      expect(blocks.map((b) => b.entryId), [first.id, second.id]);
      expect(blocks.map((b) => b.displayId).toSet(), hasLength(2));
    });

    test('one recurring entry id in two day buckets still renders twice', () {
      final event = allDayEvent();
      final first = buildManualReportForEvent(event);
      final second = first.copyWith(
        start: DateTime(2026, 9, 9, 9),
        end: DateTime(2026, 9, 9, 10),
      );
      final blocks = buildReportBlocks(
        visibleEvents: [event],
        nodes: const [],
        reportsByDay: {
          '2026-09-08': [first],
          '2026-09-09': [second],
        },
      );

      expect(blocks, hasLength(2));
      expect(blocks.map((b) => b.displayId), [
        reportAcceptedDisplayIdFor('2026-09-08', first.id),
        reportAcceptedDisplayIdFor('2026-09-09', first.id),
      ]);
    });

    test('a same-day backing-task run replaces the manual all-day entry', () {
      final start = DateTime(2026, 9, 8, 9, 10);
      final session = TimeSession(
        id: TimeSession.idFor(start, start.add(const Duration(minutes: 30))),
        start: start,
        end: start.add(const Duration(minutes: 30)),
      );
      final entry = buildManualReportForEvent(allDayEvent(taskId: 'task'));
      final blocks = buildReportBlocks(
        visibleEvents: [allDayEvent(taskId: 'task')],
        nodes: [
          Node(
            id: 'task',
            title: 'Essay',
            createdAt: DateTime(2026, 9, 1),
            calendarEventId: 'e1',
            sessions: [session],
            actualStart: session.start,
            actualEnd: session.end,
          ),
        ],
        reportsByDay: {
          '2026-09-08': [entry],
        },
      );

      expect(blocks, hasLength(1));
      final timer = blocks.single;
      expect(timer.kind, ReportBlockKind.timer);
      expect(timer.sessionId, session.id);
      // The node-only pass owns this run; the all-day row must not mirror it.
      expect(timer.eventId, isNull);
      expect(blocks.where((b) => b.kind == ReportBlockKind.accepted), isEmpty);
      expect(blocks.where((b) => b.kind == ReportBlockKind.live), isEmpty);
    });

    test('a same-day live backing task replaces the manual all-day entry', () {
      final started = DateTime(2026, 9, 8, 9, 10);
      final entry = buildManualReportForEvent(allDayEvent(taskId: 'task'));
      final blocks = buildReportBlocks(
        visibleEvents: [allDayEvent(taskId: 'task')],
        nodes: [
          Node(
            id: 'task',
            title: 'Essay',
            createdAt: DateTime(2026, 9, 1),
            calendarEventId: 'e1',
            timerStartedAt: started,
          ),
        ],
        reportsByDay: {
          '2026-09-08': [entry],
        },
        now: DateTime(2026, 9, 8, 12),
      );

      expect(blocks, hasLength(1));
      expect(blocks.single.kind, ReportBlockKind.live);
      expect(blocks.single.start, started);
      expect(blocks.where((b) => b.kind == ReportBlockKind.accepted), isEmpty);
    });

    test('a manual entry on another day survives a same-day task run', () {
      final start = DateTime(2026, 9, 8, 9, 10);
      final session = TimeSession(
        id: TimeSession.idFor(start, start.add(const Duration(minutes: 30))),
        start: start,
        end: start.add(const Duration(minutes: 30)),
      );
      final entry = buildManualReportForEvent(allDayEvent(taskId: 'task'))
          .copyWith(
            start: DateTime(2026, 9, 9, 13),
            end: DateTime(2026, 9, 9, 14),
          );
      final blocks = buildReportBlocks(
        visibleEvents: [allDayEvent(taskId: 'task')],
        nodes: [
          Node(
            id: 'task',
            title: 'Essay',
            createdAt: DateTime(2026, 9, 1),
            calendarEventId: 'e1',
            sessions: [session],
            actualStart: session.start,
            actualEnd: session.end,
          ),
        ],
        reportsByDay: {
          '2026-09-09': [entry],
        },
      );

      expect(blocks, hasLength(2));
      expect(blocks.map((b) => b.kind), [
        ReportBlockKind.timer,
        ReportBlockKind.accepted,
      ]);
      expect(blocks.last.entryId, entry.id);
    });

    test('an all-day event without a report still produces no blocks', () {
      final blocks = buildReportBlocks(
        visibleEvents: [allDayEvent()],
        nodes: const [],
        reportsByDay: const {},
      );
      expect(blocks, isEmpty);
    });
  });
}
