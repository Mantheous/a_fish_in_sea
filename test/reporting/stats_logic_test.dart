import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/model/assignment_estimate.dart';
import 'package:a_fish_in_sea/planner/model/assignment_rule.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:a_fish_in_sea/reporting/reporting_logic.dart';
import 'package:a_fish_in_sea/reporting/stats_logic.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wednesday 2026-10-14, safely inside the Oct 12–18 week.
final _monday = DateTime(2026, 10, 12);

/// [offset] days after Monday of that week, at [hour]:[minute].
DateTime dayOn(int offset, [int hour = 12, int minute = 0]) =>
    _monday.add(Duration(days: offset, hours: hour, minutes: minute));

StatsRange get _thisWeek => statsRangeFor(
      StatsRangePreset.thisWeek,
      now: _monday.add(const Duration(days: 2, hours: 9)),
    );

Node homework({
  String id = 'n1',
  String title = 'Video Quiz 3.1',
  String feedId = 'math290',
  String classLabel = 'MATH 290',
  DateTime? start,
  int minutes = 60,
  DateTime? due,
  DateTime? completedAt,
  bool done = false,
  bool reported = true,
}) {
  final at = start ?? dayOn(1, 9);
  return Node(
    id: id,
    title: title,
    createdAt: DateTime(2026, 9, 1),
    feedId: feedId,
    classId: feedId,
    classLabel: classLabel,
    sourceEventId: 'evt:$id',
    schedule: ScheduleFacet(
      due: due ?? dayOn(2, 23),
      start: at,
      end: at.add(Duration(minutes: minutes)),
    ),
    actualStart: reported ? at : null,
    actualEnd: reported ? at.add(Duration(minutes: minutes)) : null,
    completedAt: completedAt,
    status: done ? NodeStatus.done : NodeStatus.open,
  );
}

PlannedSlice slice({
  String id = 'slice:1',
  String title = 'Video Quiz 3.1',
  String? taskId,
  String? classLabel,
  required DateTime start,
  Duration duration = const Duration(hours: 1),
}) {
  return PlannedSlice(
    eventId: id,
    title: title,
    taskId: taskId,
    classLabel: classLabel,
    start: start,
    end: start.add(duration),
  );
}

Node lecture() => Node(
      id: 'n:lecture',
      title: 'MATH 290 lecture',
      createdAt: DateTime(2026, 9, 1),
      feedId: 'math290',
      classId: 'math290',
      classLabel: 'MATH 290',
    );

void main() {

  group('stats ranges', () {
    test('this week is Monday to Monday', () {
      final range = statsRangeFor(
        StatsRangePreset.thisWeek,
        now: DateTime(2026, 10, 14, 12),
      );
      expect(range.start, DateTime(2026, 10, 12));
      expect(range.days, 7);
    });

    test('containment is start-inclusive, end-exclusive', () {
      final range = statsRangeFor(
        StatsRangePreset.thisWeek,
        now: DateTime(2026, 10, 14, 12),
      );
      expect(range.contains(DateTime(2026, 10, 12, 0)), isTrue);
      expect(range.contains(DateTime(2026, 10, 18, 23, 59)), isTrue);
      expect(range.contains(DateTime(2026, 10, 19, 0)), isFalse);
      expect(range.contains(DateTime(2026, 10, 11, 23, 59)), isFalse);
    });

    test('last 30 days includes today', () {
      final range = statsRangeFor(
        StatsRangePreset.last30,
        now: DateTime(2026, 10, 14, 12),
      );
      expect(range.days, 30);
      expect(range.contains(DateTime(2026, 10, 14, 12)), isTrue);
      expect(range.contains(DateTime(2026, 9, 15, 12)), isTrue);
      expect(range.contains(DateTime(2026, 9, 14, 12)), isFalse);
    });

    test('weekStartOf is Monday regardless of the weekday given', () {
      expect(weekStartOf(DateTime(2026, 10, 12)), DateTime(2026, 10, 12));
      expect(weekStartOf(DateTime(2026, 10, 18)), DateTime(2026, 10, 12));
    });
  });

  group('buildAssignmentTimeReport', () {
    test('counts recorded time and nothing else', () {
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: [
          homework(
            id: 'a',
            start: dayOn(1, 9),
            minutes: 90,
          ),
        ],
      );
      expect(report.trackedMinutes, 90);
      expect(report.plannedMinutes, 0);
      expect(report.rows, hasLength(1));
      expect(report.rows.single.classLabel, 'MATH 290');
    });

    test('counts time recorded on a plain calendar event', () {
      final start = dayOn(1, 9);
      final end = start.add(const Duration(minutes: 90));
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: const [],
        events: [
          PlannerEvent(
            id: 'evt:library',
            subject: 'Study at the library',
            classLabel: 'BIO 100',
            start: start,
            end: start.add(const Duration(hours: 1)),
            sessions: [
              TimeSession(id: TimeSession.idFor(start, end), start: start, end: end),
            ],
          ),
        ],
      );
      expect(report.trackedMinutes, 90);
      final bio = report.byClass.firstWhere((g) => g.label == 'BIO 100');
      expect(bio.trackedMinutes, 90);
    });

    test('counts a running timer up to now', () {
      final start = dayOn(1, 9);
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: [
          Node(
            id: 'n:live',
            title: 'Focus',
            createdAt: _monday,
            timerStartedAt: start,
          ),
        ],
        now: start.add(const Duration(minutes: 25)),
      );
      expect(report.trackedMinutes, 25);
    });

    test('mirrored task and event sessions count once', () {
      final start = dayOn(1, 9);
      final session = TimeSession(
        id: TimeSession.idFor(start, start.add(const Duration(minutes: 30))),
        start: start,
        end: start.add(const Duration(minutes: 30)),
      );
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: [
          Node(
            id: 'n1',
            title: 'Quiz',
            createdAt: _monday,
            calendarEventId: 'evt:1',
            sessions: [session],
            actualStart: session.start,
            actualEnd: session.end,
          ),
        ],
        events: [
          PlannerEvent(
            id: 'evt:1',
            subject: 'Quiz',
            start: start,
            end: start.add(const Duration(hours: 1)),
            taskId: 'n1',
            sessions: [session],
            actualStart: session.start,
            actualEnd: session.end,
          ),
        ],
      );
      expect(report.trackedMinutes, 30);
    });

    test('counts a planned block with no timer as planned', () {
      final node = homework(id: 'a', reported: false);
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: [
          slice(
            taskId: 'a',
            classLabel: 'MATH 290',
            start: dayOn(1, 9),
            duration: const Duration(hours: 2),
          ),
        ],
        nodes: [node],
      );
      expect(report.trackedMinutes, 0);
      expect(report.plannedMinutes, 120);
      final math = report.byClass.firstWhere((g) => g.label == 'MATH 290');
      expect(math.plannedMinutes, 120);
      expect(math.trackedMinutes, 0);
    });

    test('a session inside its block is not counted twice', () {
      final start = dayOn(1, 9);
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: [
          slice(
            taskId: 'a',
            classLabel: 'MATH 290',
            start: start,
            duration: const Duration(hours: 2),
          ),
        ],
        nodes: [
          homework(id: 'a', start: start, minutes: 60),
        ],
      );
      // 2 hours planned, 1 of which was recorded: the class total is the
      // union (2h), not the sum (3h).
      final math = report.byClass.firstWhere((g) => g.label == 'MATH 290');
      expect(math.totalMinutes, 120);
      expect(math.trackedMinutes, 60);
      expect(math.plannedMinutes, 60);
      // Covered time is also the union, not 3 hours.
      expect(report.days.single.coveredMinutes, 120);
    });

    test('all-day slices are ignored', () {
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: [
          PlannedSlice(
            eventId: 'allday',
            title: 'Fall break',
            start: dayOn(1),
            end: dayOn(1),
            allDay: true,
          ),
        ],
        nodes: const [],
      );
      expect(report.plannedMinutes, 0);
      expect(report.hasData, isFalse);
    });

    test('records the day-level unaccounted gap', () {
      final start = dayOn(1, 9);
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: [
          homework(id: 'a', start: start, minutes: 60),
        ],
      );
      // The waking window is 7am-midnight; one hour of work on an active
      // day leaves the other sixteen hours unaccounted.
      expect(report.days.single.windowMinutes, statsWakingMinutes);
      expect(report.days.single.coveredMinutes, 60);
      expect(report.days.single.unaccountedMinutes, statsWakingMinutes - 60);
      expect(report.unaccountedMinutes, statsWakingMinutes - 60);
    });

    test('a day with nothing recorded contributes nothing', () {
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: [
          slice(start: dayOn(3), duration: const Duration(hours: 3)),
        ],
        nodes: const [],
      );
      // The slice has no taskId, so it is a plain calendar block with no
      // owner: it still counts as planned time, but the day still has a
      // gap to report.
      expect(report.plannedMinutes, 180);
      expect(report.days.single.windowMinutes, statsWakingMinutes);
      expect(report.days.single.unaccountedMinutes, statsWakingMinutes - 180);
    });

    test('groups by class', () {
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: [
          homework(
            id: 'a',
            feedId: 'math290',
            classLabel: 'MATH 290',
            start: dayOn(1, 9),
            minutes: 60,
          ),
          homework(
            id: 'b',
            title: 'Problem Set 5',
            feedId: 'stat230',
            classLabel: 'STAT 230',
            start: dayOn(2, 9),
            minutes: 40,
          ),
        ],
      );
      final byLabel = {for (final g in report.byClass) g.label: g.totalMinutes};
      expect(byLabel['MATH 290'], 60);
      expect(byLabel['STAT 230'], 40);
    });

    test('groups by classified assignment type, not by title', () {
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: [
          homework(
            id: 'a',
            title: 'Video Quiz 3.1',
            start: dayOn(1, 9),
            minutes: 30,
          ),
          homework(
            id: 'b',
            title: 'Video Quiz 3.4b',
            start: dayOn(2, 19),
            minutes: 45,
          ),
        ],
      );
      expect(report.byType, hasLength(1));
      final type = report.byType.single;
      expect(type.key, 'math290|video quiz');
      expect(type.totalMinutes, 75);
      expect(type.assignmentCount, 2);
      expect(type.label, 'Video Quiz');
    });

    test('estimates come from the learned average', () {
      final nodes = [
        homework(id: 'a', title: 'Video Quiz 3.1', minutes: 30),
        homework(id: 'b', title: 'Video Quiz 3.4b', minutes: 50),
      ];
      final efforts = learnEffortIndex(nodes);
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: nodes,
        efforts: efforts,
      );
      // Median of [30, 50] = 40.
      expect(report.rows.map((r) => r.estimateMinutes), [40, 40]);
    });

    test('a rule estimate wins over the learned average', () {
      final nodes = [homework(id: 'a', minutes: 30)];
      final efforts = learnEffortIndex(nodes);
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: nodes,
        efforts: efforts,
        rules: [
          AssignmentRule(
            id: 'r1',
            feedId: 'math290',
            templateKey: 'video quiz',
            displayName: 'Video Quiz',
            dueOffsetDays: 0,
            estimateMinutes: 15,
            createdAt: DateTime(2026, 10, 1),
          ),
        ],
      );
      expect(report.rows.single.estimateMinutes, 15);
    });

    test('estimate accuracy compares what was guessed to what happened', () {
      final nodes = [
        homework(id: 'a', minutes: 60),
        homework(id: 'b', minutes: 90),
      ];
      final efforts = learnEffortIndex(nodes);
      final rules = [
        AssignmentRule(
          id: 'r1',
          feedId: 'math290',
          templateKey: 'video quiz',
          displayName: 'Video Quiz',
          dueOffsetDays: 0,
          estimateMinutes: 50,
          createdAt: DateTime(2026, 10, 1),
        ),
      ];
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: nodes,
        efforts: efforts,
        rules: rules,
      );
      // Guessed 50 each, recorded 60 and 90 (total 150).
      expect(report.estimateAccuracy, closeTo(100 / 150, 0.001));
    });

    test('ignores work outside the range', () {
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: [
          homework(
            id: 'a',
            start: DateTime(2026, 9, 1, 9),
            minutes: 120,
          ),
        ],
      );
      expect(report.trackedMinutes, 0);
      expect(report.rows, isEmpty);
    });

    test('counts assignments finished in the range', () {
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: [
          homework(
            id: 'a',
            done: true,
            completedAt: dayOn(2, 15),
            start: dayOn(2, 9),
            minutes: 120,
          ),
          homework(id: 'b', done: true, completedAt: DateTime(2026, 9, 1)),
        ],
      );
      expect(report.assignmentsCompleted, 1);
    });

    test('reported entries with no backing node are not double counted', () {
      final start = dayOn(1, 9);
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: [
          homework(id: 'a', start: start, minutes: 60),
        ],
        reportedEntries: [
          ReportedEntry(
            id: 'rep:evt:a',
            eventId: 'evt:a',
            title: 'Video Quiz',
            start: start,
            end: start.add(const Duration(hours: 1)),
            status: ReportStatus.attended,
            auto: false,
          ),
        ],
      );
      // The node already carries the report; the manual entry for the same
      // event is the same hour, not a second one.
      expect(report.trackedMinutes, 60);
    });

    test('a manual report for an unbacked event still counts', () {
      final start = dayOn(1, 9);
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: const [],
        reportedEntries: [
          ReportedEntry(
            id: 'rep:evt:personal',
            eventId: 'evt:personal',
            title: 'Temple trip',
            start: start,
            end: start.add(const Duration(minutes: 45)),
            status: ReportStatus.attended,
            auto: false,
          ),
        ],
      );
      expect(report.trackedMinutes, 45);
      expect(report.trackedNotPlannedMinutes, 45);
    });

    test('a manual report on a task with no timer still counts', () {
      final start = dayOn(1, 9);
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: [
          Node(
            id: 'n1',
            title: 'Quiz',
            createdAt: _monday,
            calendarEventId: 'evt:1',
          ),
        ],
        events: [
          PlannerEvent(
            id: 'evt:1',
            subject: 'Quiz',
            start: start,
            end: start.add(const Duration(hours: 1)),
            taskId: 'n1',
          ),
        ],
        reportedEntries: [
          ReportedEntry(
            id: 'rep:evt:1',
            eventId: 'evt:1',
            title: 'Quiz',
            start: start,
            end: start.add(const Duration(minutes: 45)),
            status: ReportStatus.attended,
            auto: false,
          ),
        ],
      );
      expect(report.trackedMinutes, 45);
    });

    test('missed and auto entries do not count as tracked time', () {
      final start = dayOn(1, 9);
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: const [],
        reportedEntries: [
          // Skipped everything and ran Auto-report: the auto "missed" is
          // the absence of work, not work.
          ReportedEntry(
            id: 'rep:auto-missed',
            eventId: 'evt:skipped',
            title: 'Skipped lecture',
            start: start,
            end: start.add(const Duration(hours: 1)),
            status: ReportStatus.missed,
            auto: true,
          ),
          // A manually-marked miss is still not work done.
          ReportedEntry(
            id: 'rep:manual-missed',
            eventId: 'evt:skipped-2',
            title: 'Skipped seminar',
            start: start.add(const Duration(hours: 2)),
            end: start.add(const Duration(hours: 3)),
            status: ReportStatus.missed,
            auto: false,
          ),
          // An unconfirmed auto "attended" is a guess, not a record.
          ReportedEntry(
            id: 'rep:auto-attended',
            eventId: 'evt:maybe',
            title: 'Maybe there',
            start: start.add(const Duration(hours: 4)),
            end: start.add(const Duration(hours: 5)),
            status: ReportStatus.attended,
            auto: true,
          ),
          ReportedEntry(
            id: 'rep:manual-attended',
            eventId: 'evt:real',
            title: 'Temple trip',
            start: start.add(const Duration(hours: 6)),
            end: start.add(const Duration(minutes: 45 + 360)),
            status: ReportStatus.attended,
            auto: false,
          ),
        ],
      );
      // Only the confirmed manual attendance counts.
      expect(report.trackedMinutes, 45);
      expect(report.trackedNotPlannedMinutes, 45);
    });

    test('an overnight session splits at midnight', () {
      final start = DateTime(2026, 10, 13, 22);
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: [
          homework(
            id: 'a',
            start: start,
            minutes: 600,
          ),
        ],
      );
      // 22:00-24:00 lands on Tuesday, 00:00-07:00 is night (outside the
      // waking window), 07:00-08:00 lands on Wednesday.
      expect(report.trackedMinutes, 180);
      expect(report.days, hasLength(2));
      final tuesday = report.days
          .firstWhere((d) => d.day == DateTime(2026, 10, 13));
      final wednesday = report.days
          .firstWhere((d) => d.day == DateTime(2026, 10, 14));
      expect(tuesday.coveredMinutes, 120);
      expect(wednesday.coveredMinutes, 60);
    });

    test('night-only work carries no window penalty', () {
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: [
          homework(
            id: 'a',
            start: dayOn(1, 2),
            minutes: 60,
          ),
        ],
      );
      // 02:00-03:00 is outside the waking window: nothing is counted, and
      // the day is not penalized with 17 "not accounted for" hours.
      expect(report.trackedMinutes, 0);
      expect(report.days.single.windowMinutes, 0);
      expect(report.days.single.coveredMinutes, 0);
      expect(report.unaccountedMinutes, 0);
    });

    test('overlapping planned and tracked fit under the covered axis', () {
      final start = dayOn(1, 9);
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: [
          slice(
            taskId: 'a',
            classLabel: 'MATH 290',
            start: start,
            duration: const Duration(hours: 2),
          ),
        ],
        nodes: [
          homework(id: 'a', start: start, minutes: 60),
        ],
      );
      final day = report.days.single;
      // Planned is net of the recorded overlap, so the two chart rods
      // (tracked vs. planned) never sum past the covered axis max.
      expect(day.trackedMinutes, 60);
      expect(day.plannedMinutes, 60);
      expect(day.coveredMinutes, 120);
      expect(day.trackedMinutes + day.plannedMinutes,
          lessThanOrEqualTo(day.coveredMinutes));
    });

    test('an empty range reports nothing', () {
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: const [],
      );
      expect(report.hasData, isFalse);
      expect(report.byClass, isEmpty);
      expect(report.byType, isEmpty);
      expect(report.trackedMinutes, 0);
    });

    test('recorded time on a non-homework goal counts as well', () {
      // A session on a time goal is real work the user did: leaving it out
      // of the accounting would make "not accounted for" lie about it.
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: [
          Node(
            id: 'g1',
            title: 'Lift',
            createdAt: _monday,
            effort: const EffortFacet(targetMinutes: 180),
            actualStart: dayOn(1, 7),
            actualEnd: dayOn(1, 8),
          ),
        ],
      );
      expect(report.trackedMinutes, 60);
      // It is not an assignment, so it never appears in the per-type list.
      expect(report.byType, isEmpty);
      expect(report.byClass.single.label, 'No class');
    });

    test('a lecture block with no homework link counts as class time', () {
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: [
          slice(
            id: 'evt:lecture',
            title: 'MATH 290 lecture',
            classLabel: 'MATH 290',
            start: dayOn(1, 12),
            duration: const Duration(minutes: 50),
          ),
        ],
        nodes: [lecture()],
      );
      final math = report.byClass.firstWhere((g) => g.label == 'MATH 290');
      expect(math.plannedMinutes, 50);
      // Lectures are not classified assignment types.
      expect(report.byType, isEmpty);
    });

    test('off-plan work is reported separately', () {
      final start = dayOn(1, 22);
      final report = buildAssignmentTimeReport(
        range: _thisWeek,
        plannedSlices: const [],
        nodes: [
          homework(id: 'a', start: start, minutes: 30),
        ],
      );
      expect(report.trackedNotPlannedMinutes, 30);
    });

    test('DST weeks stay seven calendar days', () {
      // US fall-back Sunday Nov 1 2026: the week is 169 hours long. The
      // old `start + 7*24h` ended Sunday at 23:00 and reported 6 days.
      final range = statsRangeFor(
        StatsRangePreset.thisWeek,
        now: DateTime(2026, 11, 1, 12),
      );
      expect(range.start, DateTime(2026, 10, 26));
      expect(range.end, DateTime(2026, 11, 2));
      expect(range.days, 7);
      expect(range.contains(DateTime(2026, 11, 1, 23, 59)), isTrue);
      expect(range.contains(DateTime(2026, 11, 2, 0, 1)), isFalse);
    });

    test('overnight sessions split across a fall-back midnight', () {
      // A 13-hour real session from 20:00 Nov 1 to 09:00 Nov 2 spans the
      // 25-hour day. Before the fix, the second split recomputed the same
      // 23:00 day end and looped forever.
      final entry = ReportedEntry(
        id: 'r1',
        title: 'Late session',
        start: DateTime(2026, 11, 1, 20),
        end: DateTime(2026, 11, 2, 9),
        status: ReportStatus.attended,
        auto: false,
      );
      final report = buildAssignmentTimeReport(
        range: StatsRange(
          start: DateTime(2026, 11, 1),
          end: DateTime(2026, 11, 3),
          preset: StatsRangePreset.last30,
        ),
        plannedSlices: const [],
        nodes: const [],
        reportedEntries: [entry],
      );
      // Waking window clips the post-midnight piece to 07:00–09:00.
      expect(report.days, hasLength(2));
      expect(report.trackedMinutes, 240 + 120);
    });
  });

  group('buildGoalRangeReport', () {
    test('lists goals finished in the range', () {
      final report = buildGoalRangeReport(
        range: _thisWeek,
        nodes: [
          Node(
            id: 'g1',
            title: 'Run a 10k',
            createdAt: DateTime(2026),
            status: NodeStatus.done,
            completedAt: dayOn(2, 18),
          ),
          Node(
            id: 'g2',
            title: 'Finished last week',
            createdAt: DateTime(2026),
            status: NodeStatus.done,
            completedAt: _monday.subtract(const Duration(days: 1)),
          ),
        ],
      );
      expect(report.completed, hasLength(1));
      expect(report.completed.single.node.title, 'Run a 10k');
      expect(report.completed.single.kind, GoalKind.checklist);
    });

    test('homework is not a goal', () {
      final report = buildGoalRangeReport(
        range: _thisWeek,
        nodes: [
          homework(id: 'a', done: true, completedAt: dayOn(2, 15)),
        ],
      );
      expect(report.completed, isEmpty);
      expect(report.hasData, isFalse);
    });

    test('counts checklist leaves, not their containers', () {
      final report = buildGoalRangeReport(
        range: _thisWeek,
        nodes: [
          Node(id: 'parent', title: 'Weekly list', createdAt: DateTime(2026)),
          Node(
            id: 'leaf1',
            title: 'Done thing',
            createdAt: DateTime(2026),
            parentIds: const ['parent'],
            status: NodeStatus.done,
            completedAt: dayOn(1, 10),
          ),
          Node(
            id: 'leaf2',
            title: 'Open thing',
            createdAt: DateTime(2026),
            parentIds: const ['parent'],
          ),
        ],
      );
      expect(report.checklistTotal, 2);
      expect(report.checklistDone, 1);
      expect(report.checklistPct, closeTo(0.5, 0.001));
    });

    test('summarises time goals against their target', () {
      final report = buildGoalRangeReport(
        range: _thisWeek,
        nodes: [
          Node(
            id: 'g1',
            title: 'Weightlifting',
            createdAt: DateTime(2026),
            effort: const EffortFacet(targetMinutes: 180),
            actualStart: dayOn(1, 7),
            actualEnd: dayOn(1, 8),
          ),
          Node(
            id: 'g2',
            title: 'Scripture study',
            createdAt: DateTime(2026),
            effort: const EffortFacet(targetMinutes: 60),
          ),
        ],
      );
      expect(report.effortGoalCount, 2);
      expect(report.effortTargetMinutes, 240);
      expect(report.effortLoggedMinutes, 60);
      expect(report.effortPct, closeTo(0.25, 0.001));
    });

    test('summarises money goals', () {
      final report = buildGoalRangeReport(
        range: _thisWeek,
        nodes: [
          Node(
            id: 'm1',
            title: 'Emergency fund',
            createdAt: DateTime(2026),
            money: const MoneyFacet(
              targetAmount: 500,
              actualAmount: 125,
              direction: MoneyDirection.save,
            ),
          ),
        ],
      );
      expect(report.moneyGoalCount, 1);
      expect(report.moneyTarget, 500);
      expect(report.moneyActual, 125);
      expect(report.moneyPct, closeTo(0.25, 0.001));
    });

    test('summarises review goals', () {
      final report = buildGoalRangeReport(
        range: _thisWeek,
        nodes: [
          Node(
            id: 'a1',
            title: 'Anki deck',
            createdAt: DateTime(2026),
            anki: const AnkiFacet(
              deckName: 'Japanese',
              targetReviews: 20,
              reviewsActual: 5,
            ),
          ),
        ],
      );
      expect(report.ankiGoalCount, 1);
      expect(report.ankiReviews, 5);
      expect(report.ankiTarget, 20);
    });

    test('done money and time goals keep their metrics', () {
      final report = buildGoalRangeReport(
        range: _thisWeek,
        nodes: [
          Node(
            id: 'm1',
            title: 'Emergency fund',
            createdAt: DateTime(2026),
            money: const MoneyFacet(
              targetAmount: 500,
              actualAmount: 125,
              direction: MoneyDirection.save,
            ),
            status: NodeStatus.done,
            completedAt: dayOn(2, 18),
          ),
          Node(
            id: 'g1',
            title: 'Weightlifting',
            createdAt: DateTime(2026),
            effort: const EffortFacet(targetMinutes: 180),
            actualStart: dayOn(1, 7),
            actualEnd: dayOn(1, 8),
            status: NodeStatus.done,
            completedAt: dayOn(2, 10),
          ),
        ],
      );
      // Marking a goal Done lists it as finished without erasing its
      // target and logged progress from the totals.
      expect(report.completed, hasLength(2));
      expect(report.moneyGoalCount, 1);
      expect(report.moneyTarget, 500);
      expect(report.moneyActual, 125);
      expect(report.effortGoalCount, 1);
      expect(report.effortTargetMinutes, 180);
      expect(report.effortLoggedMinutes, 60);
    });

    test('a zero money target yields no progress, not NaN', () {
      final report = buildGoalRangeReport(
        range: _thisWeek,
        nodes: [
          Node(
            id: 'm1',
            title: 'Spare change',
            createdAt: DateTime(2026),
            money: const MoneyFacet(
              targetAmount: 0,
              actualAmount: 0,
              direction: MoneyDirection.save,
            ),
          ),
        ],
      );
      expect(report.moneyGoalCount, 1);
      // Null so the page can show an empty bar instead of dividing by zero.
      expect(report.moneyPct, isNull);
    });

    test('counts overdue open goals', () {
      final report = buildGoalRangeReport(
        range: _thisWeek,
        // Pin "now" to the fixture week: with a rolling DateTime.now both
        // fixtures are overdue once the real week passes (pre-existing
        // date drift, unrelated to this change).
        now: dayOn(2, 12),
        nodes: [
          Node(
            id: 'g1',
            title: 'Missed it',
            createdAt: DateTime(2026),
            schedule: ScheduleFacet(due: _monday.subtract(const Duration(days: 2))),
          ),
          Node(
            id: 'g2',
            title: 'Still fine',
            createdAt: DateTime(2026),
            schedule: ScheduleFacet(due: _monday.add(const Duration(days: 5))),
          ),
        ],
      );
      expect(report.overdue, 1);
      expect(report.open, 2);
    });

    test('skips templates and unbounded directions', () {
      final report = buildGoalRangeReport(
        range: _thisWeek,
        nodes: [
          Node(
            id: 't',
            title: 'Weekly review',
            createdAt: DateTime(2026),
            recurrence: const NodeRecurrence(frequency: TimeScale.weekly),
          ),
          Node(
            id: 'u',
            title: 'Serve others',
            createdAt: DateTime(2026),
            isUnbounded: true,
            effort: const EffortFacet(targetMinutes: 600),
          ),
        ],
      );
      expect(report.effortGoalCount, 0);
      expect(report.open, 0);
      expect(report.hasData, isFalse);
    });
  });
}
