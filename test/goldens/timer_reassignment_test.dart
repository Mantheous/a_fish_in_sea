import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/nodes/view/timer_edit_sheet.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/calendar_report.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_app.dart';

void main() {
  for (final scenario in ['unlinked', 'linked', 'legacy']) {
    testWidgets('moving a $scenario chunk transfers only its mirrors', (
      tester,
    ) async {
      await pumpGoldenPage(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showEditNodeTimerSheet(context, nodeId: 'source'),
            child: const Text('Adjust'),
          ),
        ),
      );
      final context = tester.element(find.text('Adjust'));
      final nodes = context.read<NodeCubit>();
      final calendar = context.read<CalendarCubit>();
      final undo = context.read<UndoCubit>();
      final start = DateTime(2026, 10, 5, 9);
      final end = start.add(const Duration(hours: 1));
      nodes.addNode(
        Node(
          id: 'source',
          title: 'Scheduled task',
          createdAt: start,
          calendarEventId: 'direct',
          sourceEventId: 'imported',
        ),
      );
      nodes.addNode(
        Node(id: 'destination', title: 'New goal', createdAt: start),
      );
      for (final id in [
        'task',
        'direct',
        'imported',
        'other',
        if (scenario == 'linked') 'destination',
      ]) {
        calendar.addEvent(
          PlannerEvent(
            id: id,
            subject: id,
            isTask: true,
            start: start,
            end: end,
            taskId: id == 'task'
                ? 'source'
                : id == 'destination'
                ? id
                : null,
          ),
        );
      }
      NodeEventLink.startNodeTracking(nodes, calendar, 'source', now: start);
      NodeEventLink.stopNodeTrackingAligned(
        nodes,
        calendar,
        'source',
        now: end,
      );
      final moved = nodes.byId('source')!.recordedSessions.single;
      for (final id in ['task', 'direct', 'imported']) {
        expect(calendar.byId(id)!.recordedSessions, [moved]);
      }
      // Identical times on an unrelated event must not be removed.
      calendar.setReported('other', start, end);
      if (scenario == 'legacy') {
        nodes.updateNode(nodes.byId('source')!.copyWith(sessions: const []));
        for (final id in ['task', 'direct', 'imported']) {
          calendar.updateEvent(calendar.byId(id)!.copyWith(sessions: const []));
        }
      }
      if (scenario == 'linked') {
        // Independent source/event runs and destination runs all survive.
        calendar.setReported('direct', end, end.add(const Duration(hours: 1)));
        calendar.updateEvent(
          calendar
              .byId('direct')!
              .copyWith(
                sessions: [moved, ...calendar.byId('direct')!.recordedSessions],
              ),
        );
        nodes.setReported(
          'destination',
          start.subtract(const Duration(hours: 1)),
          start,
        );
        calendar.setReported(
          'destination',
          end,
          end.add(const Duration(hours: 2)),
        );
      }
      final beforeNodes = nodes.state;
      final beforeEvents = calendar.state;
      undo.resetHistory();
      await tester.tap(find.text('Adjust'));
      await tester.pumpAndSettle();
      if (scenario == 'unlinked') {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('timer_reassignment_test.adjust.png'),
        );
      }
      await tester.tap(find.text('Move to another goal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New goal'));
      await tester.pumpAndSettle();
      expect(nodes.byId('source')!.recordedSessions, isEmpty);
      expect(nodes.byId('destination')!.recordedSessions, contains(moved));
      expect(
        calendar.byId('other'),
        beforeEvents.singleWhere((e) => e.id == 'other'),
      );
      for (final id in ['task', 'direct', 'imported']) {
        final remaining = calendar.byId(id)!;
        expect(
          remaining.recordedSessions.where((s) => s.id == moved.id),
          isEmpty,
        );
        expect(
          remaining.actualStart,
          scenario == 'linked' && id == 'direct' ? end : null,
        );
      }
      final blocks = buildReportBlocks(
        visibleEvents: calendar.state,
        nodes: nodes.state,
        reportsByDay: const {},
      );
      expect(blocks, hasLength(scenario == 'linked' ? 5 : 2));
      expect(
        blocks.where(
          (b) =>
              b.title == (scenario == 'linked' ? 'destination' : 'New goal') &&
              b.start == start &&
              b.end == end,
        ),
        hasLength(1),
      );
      expect(undo.state.undoStack, hasLength(1));
      final afterNodes = nodes.state;
      final afterEvents = calendar.state;
      undo.undo();
      expect(nodes.state, beforeNodes);
      expect(calendar.state, beforeEvents);
      undo.redo();
      expect(nodes.state, afterNodes);
      expect(calendar.state, afterEvents);
    });
  }
}
