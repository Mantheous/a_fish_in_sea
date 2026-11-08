import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/planner/service/weekly_time_report.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'weekly_time_report_fixtures.dart';

// Monday 2026-09-07.
final _weekStart = DateTime(2026, 9, 7);

void main() {
  group('buildWeeklyTimeReport', () {
    test('timer started from a calendar event credits its linked goal', () {
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

    test('google/feed event timer counts, unassigned lands in (no goal)', () {
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

    test('standalone node timer rolls up through the chain to the root', () {
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
        events: [event('e1', timerStartedAt: DateTime(2026, 9, 8, 9, 30))],
        reportsByDay: const {},
        weekStart: _weekStart,
        now: now,
      );
      expect(report.weekTotal, const Duration(minutes: 30));
      expect(report.entries.single.live, isTrue);
    });

    test('a live timer does not hide the runs before it', () {
      final earlier = TimeSession(
        id: TimeSession.idFor(
          DateTime(2026, 9, 8, 9, 10),
          DateTime(2026, 9, 8, 9, 40),
        ),
        start: DateTime(2026, 9, 8, 9, 10),
        end: DateTime(2026, 9, 8, 9, 40),
      );
      final liveStart = DateTime(2026, 9, 8, 14);
      final nodes = [
        node(
          'task',
          calendarEventId: 'evt:1',
          sessions: [earlier],
          actualStart: earlier.start,
          actualEnd: earlier.end,
          timerStartedAt: liveStart,
        ),
      ];
      final events = [
        event(
          'evt:1',
          taskId: 'task',
          sessions: [earlier],
          actualStart: earlier.start,
          actualEnd: earlier.end,
        ),
      ];
      final report = buildWeeklyTimeReport(
        nodes: nodes,
        events: events,
        reportsByDay: const {},
        weekStart: _weekStart,
        now: liveStart.add(const Duration(minutes: 30)),
      );

      expect(report.entries, hasLength(2));
      expect(report.entries.where((e) => e.live), hasLength(1));
      expect(report.weekTotal, const Duration(minutes: 60));
    });

    test('unscheduled task keeps stopped sessions while its timer runs', () {
      final earlier = TimeSession(
        id: 'earlier',
        start: DateTime(2026, 9, 8, 9),
        end: DateTime(2026, 9, 8, 9, 30),
      );
      final liveStart = DateTime(2026, 9, 8, 10);
      final report = buildWeeklyTimeReport(
        nodes: [
          node('goal'),
          node(
            'task',
            parents: ['goal'],
            sessions: [earlier],
            actualStart: earlier.start,
            actualEnd: earlier.end,
            timerStartedAt: liveStart,
          ),
        ],
        events: const [],
        reportsByDay: const {},
        weekStart: _weekStart,
        now: liveStart.add(const Duration(minutes: 10)),
      );

      expect(report.entries, hasLength(2));
      expect(report.entries.first.start, earlier.start);
      expect(report.entries.first.end, earlier.end);
      expect(report.entries.first.live, isFalse);
      expect(report.entries.last.start, liveStart);
      expect(report.entries.last.duration, const Duration(minutes: 10));
      expect(report.entries.last.live, isTrue);
      expect(report.weekTotal, const Duration(minutes: 40));
      expect(report.byGoal.single.goalId, 'goal');
      expect(report.byGoal.single.total, report.weekTotal);
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

    test('mirrored multi-session task counts each run once', () {
      final first = TimeSession(
        id: 'ts:1',
        start: DateTime(2026, 9, 8, 9, 10),
        end: DateTime(2026, 9, 8, 9, 40),
      );
      final second = TimeSession(
        id: 'ts:2',
        start: DateTime(2026, 9, 8, 14),
        end: DateTime(2026, 9, 8, 14, 15),
      );
      final nodes = [
        node(
          'task',
          parents: ['goal'],
          calendarEventId: 'e1',
          sessions: [first, second],
          actualStart: first.start,
          actualEnd: second.end,
        ),
        node('goal'),
      ];
      final events = [
        event(
          'e1',
          taskId: 'task',
          sessions: [first, second],
          actualStart: first.start,
          actualEnd: second.end,
        ),
      ];
      final report = buildWeeklyTimeReport(
        nodes: nodes,
        events: events,
        reportsByDay: const {},
        weekStart: _weekStart,
      );
      expect(report.entries, hasLength(2));
      expect(report.weekTotal, const Duration(minutes: 45));
      expect(report.byGoal.single.total, const Duration(minutes: 45));
    });

    test('calendar-less node counts every run separately', () {
      final first = TimeSession(
        id: 'ts:1',
        start: DateTime(2026, 9, 9, 8),
        end: DateTime(2026, 9, 9, 8, 30),
      );
      final second = TimeSession(
        id: 'ts:2',
        start: DateTime(2026, 9, 9, 18),
        end: DateTime(2026, 9, 9, 18, 20),
      );
      final report = buildWeeklyTimeReport(
        nodes: [
          node(
            'task',
            sessions: [first, second],
            actualStart: first.start,
            actualEnd: second.end,
          ),
        ],
        events: const [],
        reportsByDay: const {},
        weekStart: _weekStart,
      );
      expect(report.entries, hasLength(2));
      expect(report.weekTotal, const Duration(minutes: 50));
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

    test('mirrored stopped sessions count once even when event-owned', () {
      // stopNodeTrackingAligned copies the node's actuals onto every linked
      // event, so both events carry their own identical interval.
      final nodes = [
        node(
          'task',
          parents: ['goal'],
          actualStart: DateTime(2026, 9, 8, 9),
          actualEnd: DateTime(2026, 9, 8, 9, 30),
        ),
        node('goal'),
      ];
      final report = buildWeeklyTimeReport(
        nodes: nodes,
        events: [
          event(
            'e1',
            taskId: 'task',
            actualStart: DateTime(2026, 9, 8, 9),
            actualEnd: DateTime(2026, 9, 8, 9, 30),
          ),
          event(
            'e2',
            taskId: 'task',
            actualStart: DateTime(2026, 9, 8, 9),
            actualEnd: DateTime(2026, 9, 8, 9, 30),
          ),
        ],
        reportsByDay: const {},
        weekStart: _weekStart,
      );
      expect(report.entries, hasLength(1));
      expect(report.weekTotal, const Duration(minutes: 30));
    });

    test('old event recording does not hide this week task recording', () {
      final nodes = [
        node(
          'task',
          parents: ['goal'],
          actualStart: DateTime(2026, 9, 8, 9),
          actualEnd: DateTime(2026, 9, 8, 9, 30),
        ),
        node('goal'),
      ];
      final report = buildWeeklyTimeReport(
        nodes: nodes,
        events: [
          // Last week's recording still sits on the linked event.
          event(
            'e1',
            taskId: 'task',
            actualStart: DateTime(2026, 9, 1, 9),
            actualEnd: DateTime(2026, 9, 1, 9, 30),
          ),
        ],
        reportsByDay: const {},
        weekStart: _weekStart,
      );
      expect(report.entries, hasLength(1));
      expect(report.weekTotal, const Duration(minutes: 30));
    });

    test('distinct same-week event and task recordings both count', () {
      final nodes = [
        node(
          'task',
          parents: ['goal'],
          actualStart: DateTime(2026, 9, 8, 9),
          actualEnd: DateTime(2026, 9, 8, 9, 30),
        ),
        node('goal'),
      ];
      final report = buildWeeklyTimeReport(
        nodes: nodes,
        events: [
          event(
            'e1',
            taskId: 'task',
            actualStart: DateTime(2026, 9, 8, 8),
            actualEnd: DateTime(2026, 9, 8, 8, 30),
          ),
        ],
        reportsByDay: const {},
        weekStart: _weekStart,
      );
      expect(report.entries, hasLength(2));
      expect(report.weekTotal, const Duration(hours: 1));
    });

    test('accepted manual report on an all-day event still counts', () {
      final nodes = [
        node('goal'),
        node('task', parents: ['goal']),
      ];
      final report = buildWeeklyTimeReport(
        nodes: nodes,
        events: [event('e1', taskId: 'task', allDay: true)],
        reportsByDay: {
          '2026-09-08': [
            manual(
              id: 'rep:e1',
              eventId: 'e1',
              start: DateTime(2026, 9, 8, 9),
              end: DateTime(2026, 9, 8, 9, 45),
            ),
          ],
        },
        weekStart: _weekStart,
      );
      expect(report.weekTotal, const Duration(minutes: 45));
      expect(report.byGoal.single.title, 'Node goal');
    });

    test('weekStartFor stays on local Monday across DST nights', () {
      for (final sunday in [
        DateTime(2026, 11, 1, 23, 30), // fall back
        DateTime(2026, 3, 8, 23, 30), // spring forward
      ]) {
        final start = weekStartFor(sunday);
        expect(start.weekday, DateTime.monday);
        expect(start.hour, 0);
        expect(start.minute, 0);
        expect(sunday.difference(start).inDays, greaterThanOrEqualTo(6));
      }
    });

    test('fall-back week keeps its final hour', () {
      // US fall-back 2026-11-01: the week is 169 hours long.
      final report = buildWeeklyTimeReport(
        nodes: const [],
        events: [
          event(
            'e1',
            start: DateTime(2026, 11, 1, 23, 30),
            actualStart: DateTime(2026, 11, 1, 23, 30),
            actualEnd: DateTime(2026, 11, 1, 23, 45),
          ),
        ],
        reportsByDay: const {},
        weekStart: DateTime(2026, 10, 26),
      );
      expect(report.weekTotal, const Duration(minutes: 15));
    });

    test('spring-forward week does not include next Monday', () {
      // US spring-forward 2026-03-08: the week is 167 hours long.
      final report = buildWeeklyTimeReport(
        nodes: const [],
        events: [
          event(
            'e1',
            start: DateTime(2026, 3, 9, 0, 30),
            actualStart: DateTime(2026, 3, 9, 0, 30),
            actualEnd: DateTime(2026, 3, 9, 1),
          ),
        ],
        reportsByDay: const {},
        weekStart: DateTime(2026, 3, 2),
      );
      expect(report.weekTotal, Duration.zero);
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
