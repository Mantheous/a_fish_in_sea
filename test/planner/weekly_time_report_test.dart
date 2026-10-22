import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/weekly_time_report.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:flutter_test/flutter_test.dart';

// Monday 2026-09-07.
final _weekStart = DateTime(2026, 9, 7);

Node node(
  String id, {
  List<String> parents = const [],
  String? calendarEventId,
  DateTime? actualStart,
  DateTime? actualEnd,
  DateTime? timerStartedAt,
}) =>
    Node(
      id: id,
      title: 'Node $id',
      parentIds: parents,
      createdAt: DateTime(2026, 9, 1),
      calendarEventId: calendarEventId,
      actualStart: actualStart,
      actualEnd: actualEnd,
      timerStartedAt: timerStartedAt,
    );

PlannerEvent event(
  String id, {
  DateTime? start,
  DateTime? actualStart,
  DateTime? actualEnd,
  DateTime? timerStartedAt,
  String? taskId,
  String? feedId,
  bool allDay = false,
}) =>
    PlannerEvent(
      id: id,
      subject: 'Event $id',
      start: start ?? DateTime(2026, 9, 8, 9),
      end: (start ?? DateTime(2026, 9, 8, 9))
          .add(const Duration(hours: 1)),
      allDay: allDay,
      feedId: feedId,
      taskId: taskId,
      actualStart: actualStart,
      actualEnd: actualEnd,
      timerStartedAt: timerStartedAt,
    );

ReportedEntry manual({
  required String id,
  String? eventId,
  required DateTime start,
  required DateTime end,
}) =>
    ReportedEntry(
      id: id,
      eventId: eventId,
      title: 'Manual $id',
      start: start,
      end: end,
      status: ReportStatus.attended,
      auto: false,
    );

void main() {
  group('buildWeeklyTimeReport', () {
    test('timer started from a calendar event credits its linked goal',
        () {
      // Goal tree: task node parented under the goal, event linked via
      // taskId — the shape assignEventToGoal produces.
      final nodes = [
        node('goal'),
        node('task', parents: ['goal'], calendarEventId: 'evt:1'),
      ];
      final events = [
        event(
          'evt:1',
          taskId: 'task',
          actualStart: DateTime(2026, 9, 8, 9, 5),
          actualEnd: DateTime(2026, 9, 8, 9, 50),
        ),
      ];
      final report = buildWeeklyTimeReport(
        nodes: nodes,
        events: events,
        reportsByDay: const {},
        weekStart: _weekStart,
      );
      expect(report.weekTotal, const Duration(minutes: 45));
      expect(report.byGoal, hasLength(1));
      expect(report.byGoal.single.title, 'Node goal');
      expect(report.byGoal.single.total, const Duration(minutes: 45));
      expect(report.entries, hasLength(1));
    });

    test('google/feed event timer counts, unassigned lands in (no goal)',
        () {
      final events = [
        event(
          'g1',
          feedId: 'google:primary',
          actualStart: DateTime(2026, 9, 9, 10),
          actualEnd: DateTime(2026, 9, 9, 11),
        ),
      ];
      final report = buildWeeklyTimeReport(
        nodes: const [],
        events: events,
        reportsByDay: const {},
        weekStart: _weekStart,
      );
      expect(report.weekTotal, const Duration(hours: 1));
      expect(report.byGoal.single.title, '(no goal)');
    });

    test('standalone node timer rolls up through the chain to the root',
        () {
      final nodes = [
        node('root'),
        node('mid', parents: ['root']),
        node(
          'leaf',
          parents: ['mid'],
          actualStart: DateTime(2026, 9, 10, 14),
          actualEnd: DateTime(2026, 9, 10, 15, 30),
        ),
      ];
      final report = buildWeeklyTimeReport(
        nodes: nodes,
        events: const [],
        reportsByDay: const {},
        weekStart: _weekStart,
      );
      expect(report.byGoal.single.title, 'Node root');
      expect(report.byGoal.single.total, const Duration(minutes: 90));
    });

    test('running timer counts up to now and is marked live', () {
      final now = DateTime(2026, 9, 8, 10);
      final report = buildWeeklyTimeReport(
        nodes: const [],
        events: [
          event('e1', timerStartedAt: DateTime(2026, 9, 8, 9, 30)),
        ],
        reportsByDay: const {},
        weekStart: _weekStart,
        now: now,
      );
      expect(report.weekTotal, const Duration(minutes: 30));
      expect(report.entries.single.live, isTrue);
    });

    test('accepted manual entry is used when no timer exists', () {
      final events = [event('e1')];
      final report = buildWeeklyTimeReport(
        nodes: const [],
        events: events,
        reportsByDay: {
          '2026-09-08': [
            manual(
              id: 'rep:e1',
              eventId: 'e1',
              start: DateTime(2026, 9, 8, 9, 2),
              end: DateTime(2026, 9, 8, 9, 58),
            ),
          ],
        },
        weekStart: _weekStart,
      );
      expect(report.weekTotal, const Duration(minutes: 56));
    });

    test('event and backing node with the same session count once', () {
      final nodes = [
        node(
          'task',
          parents: ['goal'],
          calendarEventId: 'e1',
          actualStart: DateTime(2026, 9, 8, 9, 10),
          actualEnd: DateTime(2026, 9, 8, 9, 40),
        ),
        node('goal'),
      ];
      final events = [
        event(
          'e1',
          taskId: 'task',
          actualStart: DateTime(2026, 9, 8, 9, 10),
          actualEnd: DateTime(2026, 9, 8, 9, 40),
        ),
      ];
      final report = buildWeeklyTimeReport(
        nodes: nodes,
        events: events,
        reportsByDay: const {},
        weekStart: _weekStart,
      );
      expect(report.entries, hasLength(1));
      expect(report.weekTotal, const Duration(minutes: 30));
    });

    test('accepted entry is ignored when the event has a timer log', () {
      final events = [
        event(
          'e1',
          actualStart: DateTime(2026, 9, 8, 9, 5),
          actualEnd: DateTime(2026, 9, 8, 9, 50),
        ),
      ];
      final report = buildWeeklyTimeReport(
        nodes: const [],
        events: events,
        reportsByDay: {
          '2026-09-08': [
            manual(
              id: 'rep:e1',
              eventId: 'e1',
              start: DateTime(2026, 9, 8, 9),
              end: DateTime(2026, 9, 8, 12),
            ),
          ],
        },
        weekStart: _weekStart,
      );
      expect(report.entries, hasLength(1));
      expect(report.weekTotal, const Duration(minutes: 45));
    });

    test('intervals are clipped to the week window', () {
      final report = buildWeeklyTimeReport(
        nodes: const [],
        events: [
          // Sunday night spills 30 minutes into Monday.
          event(
            'e1',
            start: DateTime(2026, 9, 6, 23),
            actualStart: DateTime(2026, 9, 6, 23, 30),
            actualEnd: DateTime(2026, 9, 7, 0, 30),
          ),
          // Next Monday is outside the week entirely.
          event(
            'e2',
            start: DateTime(2026, 9, 14, 9),
            actualStart: DateTime(2026, 9, 14, 9),
            actualEnd: DateTime(2026, 9, 14, 10),
          ),
        ],
        reportsByDay: const {},
        weekStart: _weekStart,
      );
      expect(report.entries, hasLength(1));
      expect(report.weekTotal, const Duration(minutes: 30));
    });

    test('missed manual entries count as zero, linked or not', () {
      ReportedEntry missed({required String id, String? eventId}) =>
          ReportedEntry(
            id: id,
            eventId: eventId,
            title: 'Missed $id',
            start: DateTime(2026, 9, 8, 9),
            end: DateTime(2026, 9, 8, 10),
            status: ReportStatus.missed,
            auto: false,
          );
      final report = buildWeeklyTimeReport(
        nodes: [node('goal')],
        events: [event('e1', taskId: 'goal')],
        reportsByDay: {
          '2026-09-08': [
            missed(id: 'rep:e1', eventId: 'e1'),
            missed(id: 'rep:extra'),
          ],
        },
        weekStart: _weekStart,
      );
      expect(report.entries, isEmpty);
      expect(report.weekTotal, Duration.zero);
      expect(report.byGoal, isEmpty);
    });

    test('two events mirroring one task count its session once', () {
      final nodes = [
        node(
          'task',
          parents: ['goal'],
          actualStart: DateTime(2026, 9, 8, 9, 10),
          actualEnd: DateTime(2026, 9, 8, 9, 40),
        ),
        node('goal'),
      ];
      final report = buildWeeklyTimeReport(
        nodes: nodes,
        events: [
          event('e1', taskId: 'task'),
          event('e2', taskId: 'task'),
        ],
        reportsByDay: const {},
        weekStart: _weekStart,
      );
      expect(report.entries, hasLength(1));
      expect(report.weekTotal, const Duration(minutes: 30));
      expect(report.byGoal.single.total, const Duration(minutes: 30));
    });

    test('all-day event does not suppress its task timer', () {
      final nodes = [
        node(
          'task',
          parents: ['goal'],
          calendarEventId: 'e1',
          actualStart: DateTime(2026, 9, 8, 9, 10),
          actualEnd: DateTime(2026, 9, 8, 9, 40),
        ),
        node('goal'),
      ];
      final report = buildWeeklyTimeReport(
        nodes: nodes,
        events: [event('e1', taskId: 'task', allDay: true)],
        reportsByDay: const {},
        weekStart: _weekStart,
      );
      expect(report.entries, hasLength(1));
      expect(report.weekTotal, const Duration(minutes: 30));
    });

    test('goal colors are stable and (no goal) has a color', () {
      expect(goalColorFor('goal'), goalColorFor('goal'));
      expect(goalColorFor('a'), isNotNull);
      expect(goalColorFor(null), isNotNull);
    });

    test('durations format like a timesheet', () {
      expect(formatWeeklyDuration(const Duration(minutes: 45)), '45m');
      expect(formatWeeklyDuration(const Duration(minutes: 65)), '1h 05m');
      expect(
        formatWeeklyDuration(const Duration(hours: 88, minutes: 4)),
        '88h 04m',
      );
    });
  });
}
