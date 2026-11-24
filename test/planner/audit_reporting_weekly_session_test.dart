// Regression coverage for the audit finding: weekly time dedupes stopped
// runs by bare session id, so unrelated owners with colliding ids lose time.
import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/planner/service/weekly_time_report.dart';
import 'package:flutter_test/flutter_test.dart';

import 'weekly_time_report_fixtures.dart';

final _weekStart = DateTime(2026, 9, 7);

TimeSession run(String id, DateTime start, DateTime end) =>
    TimeSession(id: id, start: start, end: end);

void main() {
  group('audit: weekly session owner identity', () {
    test('unrelated tasks with a colliding session id both count', () {
      final first = run(
        'shared',
        DateTime(2026, 9, 8, 9),
        DateTime(2026, 9, 8, 9, 30),
      );
      final second = run(
        'shared',
        DateTime(2026, 9, 8, 11),
        DateTime(2026, 9, 8, 11, 45),
      );
      final report = buildWeeklyTimeReport(
        nodes: [
          node('goal'),
          node(
            'taskA',
            parents: ['goal'],
            calendarEventId: 'e1',
            sessions: [first],
            actualStart: first.start,
            actualEnd: first.end,
          ),
          node(
            'taskB',
            parents: ['goal'],
            calendarEventId: 'e2',
            sessions: [second],
            actualStart: second.start,
            actualEnd: second.end,
          ),
        ],
        events: [event('e1', taskId: 'taskA'), event('e2', taskId: 'taskB')],
        reportsByDay: const {},
        weekStart: _weekStart,
      );

      expect(report.entries, hasLength(2));
      expect(
        report.entries.map((e) => e.start),
        [first.start, second.start],
      );
      expect(report.weekTotal, const Duration(minutes: 75));
      expect(report.byGoal.single.total, const Duration(minutes: 75));
    });

    test('calendar-less nodes with a colliding session id both count', () {
      final first = run(
        'shared',
        DateTime(2026, 9, 9, 8),
        DateTime(2026, 9, 9, 8, 20),
      );
      final second = run(
        'shared',
        DateTime(2026, 9, 9, 18),
        DateTime(2026, 9, 9, 18, 40),
      );
      final report = buildWeeklyTimeReport(
        nodes: [
          node('goal'),
          node(
            'taskA',
            parents: ['goal'],
            sessions: [first],
            actualStart: first.start,
            actualEnd: first.end,
          ),
          node(
            'taskB',
            parents: ['goal'],
            sessions: [second],
            actualStart: second.start,
            actualEnd: second.end,
          ),
        ],
        events: const [],
        reportsByDay: const {},
        weekStart: _weekStart,
      );

      expect(report.entries, hasLength(2));
      expect(report.weekTotal, const Duration(minutes: 60));
    });

    test('event-owned runs with a colliding id on different events both count',
        () {
      final first = run(
        'shared',
        DateTime(2026, 9, 8, 9),
        DateTime(2026, 9, 8, 9, 30),
      );
      final second = run(
        'shared',
        DateTime(2026, 9, 8, 11),
        DateTime(2026, 9, 8, 11, 45),
      );
      final report = buildWeeklyTimeReport(
        nodes: const [],
        events: [
          event('e1', sessions: [first]),
          event('e2', sessions: [second]),
        ],
        reportsByDay: const {},
        weekStart: _weekStart,
      );

      expect(report.entries, hasLength(2));
      expect(report.weekTotal, const Duration(minutes: 75));
      expect(report.byGoal.single.title, '(no goal)');
    });

    test('node-owned and event-owned runs with the same id both count', () {
      final first = run(
        'shared',
        DateTime(2026, 9, 8, 9),
        DateTime(2026, 9, 8, 9, 30),
      );
      final second = run(
        'shared',
        DateTime(2026, 9, 8, 11),
        DateTime(2026, 9, 8, 11, 45),
      );
      final report = buildWeeklyTimeReport(
        nodes: [
          node(
            'task',
            sessions: [first],
            actualStart: first.start,
            actualEnd: first.end,
          ),
        ],
        events: [event('e1', sessions: [second])],
        reportsByDay: const {},
        weekStart: _weekStart,
      );

      expect(report.entries, hasLength(2));
      expect(report.weekTotal, const Duration(minutes: 75));
    });

    test('mirrored node and event runs still count once', () {
      final session = run(
        'shared',
        DateTime(2026, 9, 8, 9),
        DateTime(2026, 9, 8, 9, 30),
      );
      final report = buildWeeklyTimeReport(
        nodes: [
          node('goal'),
          node(
            'task',
            parents: ['goal'],
            sessions: [session],
            actualStart: session.start,
            actualEnd: session.end,
          ),
        ],
        events: [
          event('e1', taskId: 'task', sessions: [session]),
          event('e2', taskId: 'task', sessions: [session]),
        ],
        reportsByDay: const {},
        weekStart: _weekStart,
      );

      expect(report.entries, hasLength(1));
      expect(report.weekTotal, const Duration(minutes: 30));
      expect(report.byGoal.single.total, const Duration(minutes: 30));
    });
  });
}
