import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/calendar_report.dart';
import 'package:a_fish_in_sea/planner/service/weekly_time_report.dart';
import 'package:a_fish_in_sea/planner/view/calendar_report_lane.dart';
import 'package:a_fish_in_sea/planner/view/report_chip.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_app.dart';

void main() {
  for (final source in ['event', 'node', 'legacy', 'live', 'overnight']) {
    testWidgets('$source timer replaces only its recurring report day', (
      tester,
    ) async {
      final monday = DateTime(2026, 10, 5, 9);
      final tuesday = DateTime(2026, 10, 6, 9);
      final start = source == 'overnight'
          ? DateTime(2026, 10, 6, 23, 45)
          : tuesday;
      final end = start.add(const Duration(minutes: 30));
      final session = TimeSession(id: 'run', start: start, end: end);
      final event = PlannerEvent(
        id: 'daily',
        subject: 'Study',
        start: monday,
        end: monday.add(const Duration(hours: 1)),
        recurrenceRule: 'FREQ=DAILY',
        sessions: source == 'event' || source == 'overnight' ? [session] : [],
        actualStart: source == 'legacy' ? start : null,
        actualEnd: source == 'legacy' ? end : null,
        timerStartedAt: source == 'live' ? start : null,
      );
      final nodes = source == 'node'
          ? [
              Node(
                id: 'task',
                title: 'Study',
                createdAt: monday,
                calendarEventId: event.id,
                sessions: [session],
              ),
            ]
          : <Node>[];
      final reports = {
        for (final day in [
          '2026-10-05',
          '2026-10-06',
          if (source == 'overnight') '2026-10-07',
        ])
          day: [
            ReportedEntry(
              id: 'rep:daily',
              eventId: event.id,
              title: 'Saved study',
              // Tuesday's saved report was moved to Monday evening. Its
              // bucket still identifies Tuesday's occurrence for precedence.
              start: day == '2026-10-06'
                  ? monday.add(const Duration(hours: 10))
                  : DateTime.parse('${day}T09:00:00'),
              end: day == '2026-10-06'
                  ? monday.add(const Duration(hours: 11))
                  : DateTime.parse('${day}T10:00:00'),
              status: ReportStatus.attended,
              auto: false,
            ),
          ],
      };
      final blocks = buildReportBlocks(
        visibleEvents: [event],
        nodes: nodes,
        reportsByDay: reports,
        now: end,
      );
      final weekly = buildWeeklyTimeReport(
        events: [event],
        nodes: nodes,
        reportsByDay: reports,
        weekStart: DateTime(2026, 10, 5),
        now: end,
      );
      final count = source == 'overnight' ? 3 : 2;
      expect(blocks, hasLength(count));
      expect(blocks.first.kind, ReportBlockKind.accepted);
      expect(blocks.first.start, monday);
      expect(
        blocks.map((b) => b.displayId),
        isNot(contains(reportAcceptedDisplayIdFor('2026-10-06', 'rep:daily'))),
      );
      expect(weekly.entries, hasLength(count));
      expect(
        weekly.weekTotal,
        Duration(minutes: source == 'overnight' ? 150 : 90),
      );
      expect(weekly.byGoal.single.total, weekly.weekTotal);
      expect(reports['2026-10-06'], hasLength(1));
      if (source == 'event') {
        await pumpGoldenPage(
          tester,
          Column(
            children: [
              Text('Weekly total: ${formatWeeklyDuration(weekly.weekTotal)}'),
              Expanded(
                child: Row(
                  children: [
                    for (final day in [monday, tuesday])
                      Expanded(
                        child: Column(
                          children: [
                            Text(day == monday ? 'Monday' : 'Tuesday'),
                            Expanded(
                              child: ReportLaneView(
                                blocks: blocks
                                    .where((b) => b.start.day == day.day)
                                    .toList(),
                                day: day,
                                startHour: 9,
                                endHour: 11,
                                colorFor: (_) => Colors.teal,
                                onTap: (_) {},
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
        expect(find.byType(ReportChip), findsNWidgets(2));
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('recurring_report_timer.png'),
        );
      }
    });
  }
}
