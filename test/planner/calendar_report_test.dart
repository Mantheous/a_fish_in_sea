import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/model/task.dart';
import 'package:a_fish_in_sea/planner/service/calendar_report.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:flutter_test/flutter_test.dart';

PlannerEvent event(String id, DateTime start) => PlannerEvent(
      id: id,
      subject: 'Event $id',
      start: start,
      end: start.add(const Duration(hours: 1)),
    );

ReportedEntry accepted({
  required String id,
  String? eventId,
  required DateTime start,
  required DateTime end,
}) =>
    ReportedEntry(
      id: id,
      eventId: eventId,
      title: 'Accepted $id',
      start: start,
      end: end,
      status: ReportStatus.attended,
      auto: false,
    );

void main() {
  group('buildReportBlocks', () {
    test('timer-logged events become timer blocks', () {
      final base = event('e1', DateTime(2026, 9, 4, 9)).copyWith(
        actualStart: DateTime(2026, 9, 4, 9, 5),
        actualEnd: DateTime(2026, 9, 4, 9, 50),
      );
      final blocks = buildReportBlocks(
        visibleEvents: [base],
        tasks: const [],
        reportsByDay: const {},
      );
      expect(blocks, hasLength(1));
      expect(blocks.single.kind, ReportBlockKind.timer);
      expect(blocks.single.eventId, 'e1');
      expect(blocks.single.start, DateTime(2026, 9, 4, 9, 5));
      expect(blocks.single.end, DateTime(2026, 9, 4, 9, 50));
      expect(isReportDisplayId(blocks.single.displayId), isTrue);
    });

    test('currently logging events become live blocks ending at now', () {
      final now = DateTime(2026, 9, 4, 10);
      final base = event('e1', DateTime(2026, 9, 4, 9)).copyWith(
        timerStartedAt: DateTime(2026, 9, 4, 9, 30),
      );
      final blocks = buildReportBlocks(
        visibleEvents: [base],
        tasks: const [],
        reportsByDay: const {},
        now: now,
      );
      expect(blocks, hasLength(1));
      expect(blocks.single.kind, ReportBlockKind.live);
      expect(blocks.single.start, DateTime(2026, 9, 4, 9, 30));
      expect(blocks.single.end, now);
    });

    test('linked task timer stands in for its event', () {
      final base = event('e1', DateTime(2026, 9, 4, 9));
      const task = Task(
        id: 'task:e1',
        title: 'Task e1',
        calendarEventId: 'e1',
        actualStart: null,
        actualEnd: null,
      );
      final tracking = task.copyWith(
        timerStartedAt: DateTime(2026, 9, 4, 9, 10),
      );
      final live = buildReportBlocks(
        visibleEvents: [base],
        tasks: [tracking],
        reportsByDay: const {},
        now: DateTime(2026, 9, 4, 9, 40),
      );
      expect(live.single.kind, ReportBlockKind.live);

      final logged = tracking.copyWith(
        clearTimerStartedAt: true,
        actualStart: DateTime(2026, 9, 4, 9, 10),
        actualEnd: DateTime(2026, 9, 4, 9, 40),
      );
      final timer = buildReportBlocks(
        visibleEvents: [base],
        tasks: [logged],
        reportsByDay: const {},
      );
      expect(timer.single.kind, ReportBlockKind.timer);
      expect(timer.single.start, DateTime(2026, 9, 4, 9, 10));
    });

    test('accepted auto-report entries show when no timer exists', () {
      final base = event('e1', DateTime(2026, 9, 4, 9));
      final entry = accepted(
        id: 'rep:e1',
        eventId: 'e1',
        start: DateTime(2026, 9, 4, 9, 2),
        end: DateTime(2026, 9, 4, 9, 58),
      );
      final blocks = buildReportBlocks(
        visibleEvents: [base],
        tasks: const [],
        reportsByDay: {'2026-09-04': [entry]},
      );
      expect(blocks, hasLength(1));
      expect(blocks.single.kind, ReportBlockKind.accepted);
      expect(blocks.single.entryId, 'rep:e1');
    });

    test('timer takes precedence over accepted entries for the same event', () {
      final base = event('e1', DateTime(2026, 9, 4, 9)).copyWith(
        actualStart: DateTime(2026, 9, 4, 9, 5),
        actualEnd: DateTime(2026, 9, 4, 9, 50),
      );
      final entry = accepted(
        id: 'rep:e1',
        eventId: 'e1',
        start: DateTime(2026, 9, 4, 9),
        end: DateTime(2026, 9, 4, 10),
      );
      final blocks = buildReportBlocks(
        visibleEvents: [base],
        tasks: const [],
        reportsByDay: {'2026-09-04': [entry]},
      );
      expect(blocks, hasLength(1));
      expect(blocks.single.kind, ReportBlockKind.timer);
    });

    test('unaccepted auto entries and plans without reports are skipped', () {
      final planned = event('e1', DateTime(2026, 9, 4, 9));
      final auto = ReportedEntry(
        id: 'rep:e1',
        eventId: 'e1',
        title: 'Proposal',
        start: DateTime(2026, 9, 4, 9),
        end: DateTime(2026, 9, 4, 10),
        status: ReportStatus.attended,
      );
      final blocks = buildReportBlocks(
        visibleEvents: [planned],
        tasks: const [],
        reportsByDay: {'2026-09-04': [auto]},
      );
      expect(blocks, isEmpty);
    });

    test('extra accepted entries without an event are included', () {
      final extra = accepted(
        id: 'rep:extra:x:1',
        start: DateTime(2026, 9, 4, 14),
        end: DateTime(2026, 9, 4, 15),
      );
      final blocks = buildReportBlocks(
        visibleEvents: const [],
        tasks: const [],
        reportsByDay: {'2026-09-04': [extra]},
      );
      expect(blocks, hasLength(1));
      expect(blocks.single.eventId, isNull);
      expect(blocks.single.entryId, 'rep:extra:x:1');
    });

    test('all-day events are skipped', () {
      final blocks = buildReportBlocks(
        visibleEvents: [
          PlannerEvent(
            id: 'e1',
            subject: 'All day',
            start: DateTime(2026, 9, 4),
            end: DateTime(2026, 9, 5),
            allDay: true,
          ),
        ],
        tasks: const [],
        reportsByDay: const {},
      );
      expect(blocks, isEmpty);
    });
  });

  group('reportBlockToDisplayEvent', () {
    test('keeps the template look so plan/report pairs match', () {
      final template = event('e1', DateTime(2026, 9, 4, 9));
      final display = reportBlockToDisplayEvent(
        ReportBlock(
          displayId: 'report:timer:e1',
          title: 'Event e1',
          start: DateTime(2026, 9, 4, 9, 5),
          end: DateTime(2026, 9, 4, 9, 50),
          kind: ReportBlockKind.timer,
          eventId: 'e1',
        ),
        template: template,
      );
      expect(display.id, 'report:timer:e1');
      expect(display.recurrenceRule, isEmpty);
      expect(display.start, DateTime(2026, 9, 4, 9, 5));
    });
  });

  group('manual report entries for task-events', () {
    test('seeds a manual entry from the planned time', () {
      final taskEvent = PlannerEvent(
        id: 'e1',
        subject: 'Homework',
        start: DateTime(2026, 9, 4, 9),
        end: DateTime(2026, 9, 4, 10),
        isTask: true,
      );
      final entry = buildManualReportForEvent(taskEvent);
      expect(entry.id, 'rep:e1');
      expect(entry.eventId, 'e1');
      expect(entry.title, 'Homework');
      expect(entry.start, DateTime(2026, 9, 4, 9));
      expect(entry.end, DateTime(2026, 9, 4, 10));
      expect(entry.auto, isFalse);
    });

    test('prefers timer-logged time and falls back for all-day', () {
      final logged = event('e2', DateTime(2026, 9, 4, 9)).copyWith(
        actualStart: DateTime(2026, 9, 4, 9, 5),
        actualEnd: DateTime(2026, 9, 4, 9, 50),
      );
      final fromTimer = buildManualReportForEvent(logged);
      expect(fromTimer.start, DateTime(2026, 9, 4, 9, 5));
      expect(fromTimer.end, DateTime(2026, 9, 4, 9, 50));

      final allDay = PlannerEvent(
        id: 'e3',
        subject: 'All day task',
        start: DateTime(2026, 9, 4),
        end: DateTime(2026, 9, 5),
        allDay: true,
        isTask: true,
      );
      final fromAllDay = buildManualReportForEvent(allDay);
      expect(fromAllDay.end.isAfter(fromAllDay.start), isTrue);
    });

    test('find prefers manual entries over auto ones', () {
      final auto = ReportedEntry(
        id: 'rep:e1',
        eventId: 'e1',
        title: 'Study',
        start: DateTime(2026, 9, 4, 9),
        end: DateTime(2026, 9, 4, 10),
        status: ReportStatus.attended,
      );
      expect(
        findReportEntryForEvent({'2026-09-04': [auto]}, 'e1'),
        auto,
      );
      final manual = auto.copyWith(auto: false);
      expect(
        findReportEntryForEvent(
          {'2026-09-04': [auto, manual]},
          'e1',
        ),
        manual,
      );
      expect(
        findReportEntryForEvent({'2026-09-04': [auto]}, 'missing'),
        isNull,
      );
    });
  });
}
