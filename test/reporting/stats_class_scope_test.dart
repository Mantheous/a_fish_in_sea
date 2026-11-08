import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:a_fish_in_sea/reporting/reporting_logic.dart';
import 'package:a_fish_in_sea/reporting/stats_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one class row combines names, sources, manual parents and blank labels', () {
    final start = DateTime(2026, 10, 26, 9);
    final nodes = [
      Node(id: 'math', title: 'Fundamentals of Mathematics', createdAt: start,
        classFacet: const ClassFacet(sources: [ClassSource(feedId: 'canvas', classLabel: 'MATH 290-001')])),
      Node(id: 'quiz', title: 'Quiz', createdAt: start, classNodeId: 'math',
        feedId: 'canvas', classLabel: 'MATH 290-001', sourceEventId: 'quiz-event',
        actualStart: start, actualEnd: start.add(const Duration(minutes: 30))),
      Node(id: 'literature', title: 'CMLIT 202', createdAt: start, classFacet: const ClassFacet()),
      Node(id: 'manual', title: 'Read', createdAt: start,
        parentIds: const ['literature'], calendarEventId: 'manual-event'),
    ];
    final events = [
      PlannerEvent(id: 'quiz-event', subject: 'Quiz', start: start,
        end: start.add(const Duration(hours: 1)), classLabel: 'Fundamentals of Mathematics'),
      PlannerEvent(id: 'manual-event', subject: 'Read', start: start.add(const Duration(hours: 2)),
        end: start.add(const Duration(hours: 3))),
    ];
    final report = buildAssignmentTimeReport(
      range: statsRangeFor(StatsRangePreset.thisWeek, now: start), nodes: nodes, events: events,
      plannedSlices: [
        for (final event in events) PlannedSlice(eventId: event.id, title: event.subject,
          start: event.start, end: event.end, classLabel: event.classLabel),
        for (var i = 0; i < 2; i++) PlannedSlice(eventId: 'stats-$i', title: 'Statistics',
          start: start.add(Duration(hours: 4 + i)), end: start.add(Duration(hours: 5 + i)),
          classLabel: i == 0 ? 'STAT 230-002' : ' stat 230 '),
        for (var i = 0; i < 2; i++) PlannedSlice(eventId: 'blank-$i', title: 'Unbound',
          start: start.add(Duration(hours: 6 + i)), end: start.add(Duration(hours: 7 + i)),
          classLabel: i == 0 ? '' : null),
      ],
      reportedEntries: [ReportedEntry(id: 'manual-report', eventId: 'manual-event', title: 'Read',
        start: events.last.start, end: events.last.end, status: ReportStatus.attended, auto: false)],
    );
    expect({for (final row in report.byClass) row.label: row.totalMinutes},
      {'MATH 290': 60, 'CMLIT 202': 60, 'STAT 230': 120, 'No class': 120});
    expect(report.trackedMinutes, 90);
    expect(report.plannedMinutes, 270);
  });

  test('a shared feed keeps its distinct courses and never matches ambiguous names', () {
    final at = DateTime(2026, 10, 26, 9);
    final report = buildAssignmentTimeReport(
      range: statsRangeFor(StatsRangePreset.thisWeek, now: at),
      nodes: [for (final code in ['HIST 205', 'CS 236']) Node(id: code, title: 'Shared title', createdAt: at,
        classFacet: ClassFacet(sources: [ClassSource(feedId: 'shared', classLabel: code)]))],
      events: [for (final code in ['HIST 205', 'CS 236']) PlannerEvent(id: code, subject: 'Lecture',
        start: at, end: at.add(const Duration(hours: 1)), feedId: 'shared', classLabel: code)],
      plannedSlices: [for (final code in ['HIST 205', 'CS 236', 'Shared title']) PlannedSlice(
        eventId: code, title: 'Lecture', start: at, end: at.add(const Duration(hours: 1)), classLabel: code)],
    );
    expect(report.byClass.map((g) => g.label), unorderedEquals(['HIST 205', 'CS 236', 'Shared title']));
  });
}
