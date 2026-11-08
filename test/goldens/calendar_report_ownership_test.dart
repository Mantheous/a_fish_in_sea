import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/calendar_report.dart';
import 'package:a_fish_in_sea/planner/view/calendar_report_lane.dart';
import 'package:a_fish_in_sea/planner/view/report_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_app.dart';

void main() {
  for (final link in [
    'task',
    'direct',
    'source',
    'cached',
    'event',
    'legacy',
  ]) {
    testWidgets('identical intervals keep unrelated $link owners separate', (
      tester,
    ) async {
      const fixtureKey = ValueKey('fixture');
      await pumpGoldenPage(tester, const SizedBox(key: fixtureKey));
      final nodes = tester.element(find.byKey(fixtureKey)).read<NodeCubit>();
      final start = DateTime(2026, 10, 5, 9);
      final end = start.add(const Duration(hours: 1));
      for (var i = 1; i <= 2; i++) {
        nodes.addNode(
          Node(
            id: 'n$i',
            title: 'Goal $i',
            createdAt: start,
            calendarEventId: link == 'direct' ? 'e$i' : null,
            sourceEventId: link == 'source' ? 'e$i' : null,
          ),
        );
        nodes.setReported('n$i', start, end);
      }
      expect(
        nodes.state[0].sessions.single.id,
        nodes.state[1].sessions.single.id,
      );
      final hasSibling = link == 'task' || link == 'cached';
      final events = [
        for (var i = 1; i <= (hasSibling ? 3 : 2); i++)
          PlannerEvent(
            id: 'e$i',
            subject: 'Goal ${i == 3 ? 1 : i}',
            taskId: hasSibling ? 'n${i == 3 ? 1 : i}' : null,
            start: i == 3 ? start.add(const Duration(hours: 5)) : start,
            end: i == 3 ? end.add(const Duration(hours: 5)) : end,
            sessions: link == 'legacy'
                ? const []
                : nodes.byId('n${i == 3 ? 1 : i}')!.sessions,
            actualStart: start,
            actualEnd: end,
          ),
      ];
      // Both traversal orders must keep each independent recording and
      // still collapse the first goal's mirrored sibling, including when
      // only event caches remain (no loaded node).
      for (final ordered in [events, events.reversed.toList()]) {
        final blocks = buildReportBlocks(
          visibleEvents: ordered,
          nodes: ['cached', 'event', 'legacy'].contains(link)
              ? []
              : nodes.state,
          reportsByDay: const {},
        );
        expect(blocks, hasLength(2));
        expect(blocks.map((b) => b.eventId), unorderedEquals(['e1', 'e2']));
        expect(blocks.map((b) => b.displayId).toSet(), hasLength(2));
        for (final block in blocks) {
          expect(block.kind, ReportBlockKind.timer);
          expect(block.start, start);
          expect(block.end, end);
        }
        if (link == 'task' && identical(ordered, events)) {
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 480,
                    height: 240,
                    child: ReportLaneView(
                      blocks: blocks,
                      day: DateTime(2026, 10, 5),
                      startHour: 9,
                      endHour: 11,
                      colorFor: (block) =>
                          block.eventId == 'e1' ? Colors.blue : Colors.teal,
                      onTap: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(ReportChip), findsNWidgets(2));
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              'calendar_report_ownership_test.identical_times.png',
            ),
          );
        }
      }
    });
  }
}
