import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_calendar.dart';
import 'package:a_fish_in_sea/nodes/view/node_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

/// A planned task names the day it's planned on, next to its due date, so
/// the plan visibly lands before the deadline in either task list.
void main() {
  final now = DateTime(2026, 10, 25, 9);
  final due = DateTime(2026, 10, 28, 23, 59);

  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  Future<void> pumpTile(
    WidgetTester tester,
    Node node, {
    Map<String, int>? upcomingEventCounts,
    Map<String, PlannedSlot>? plannedSlots,
  }) async {
    final nodes = NodeCubit();
    nodes.addNode(node);
    addTearDown(nodes.close);
    await tester.pumpWidget(
      BlocProvider.value(
        value: nodes,
        child: MaterialApp(
          home: Scaffold(
            // Side-panel width: the planned line must wrap, not overflow,
            // where the calendar sidebar shows it.
            body: Center(
              child: SizedBox(
                width: 360,
                child: NodeTile(
                  node: node,
                  showClass: false,
                  now: now,
                  feedById: const {},
                  linkedEventIds: const {},
                  linkedTaskIds: const {},
                  upcomingEventCounts: upcomingEventCounts,
                  plannedSlots: plannedSlots,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Node task({ScheduleFacet? schedule}) => Node(
        id: 't-1',
        title: 'Essay 2',
        createdAt: DateTime(2026, 10, 1),
        schedule: schedule,
      );

  testWidgets('planned tomorrow shows the day beside the due date', (
    tester,
  ) async {
    await pumpTile(
      tester,
      task(schedule: ScheduleFacet(due: due)),
      upcomingEventCounts: const {'t-1': 1},
      plannedSlots: {
        't-1': PlannedSlot(
          start: DateTime(2026, 10, 26, 15),
          end: DateTime(2026, 10, 26, 16),
        ),
      },
    );
    expect(find.text('Due Wed, Oct 28'), findsOneWidget);
    expect(
      find.text('Planned tomorrow, 3:00 PM – 4:00 PM'),
      findsOneWidget,
    );
  });

  testWidgets('a later plan names the weekday and date', (tester) async {
    await pumpTile(
      tester,
      task(schedule: ScheduleFacet(due: due)),
      upcomingEventCounts: const {'t-1': 1},
      plannedSlots: {
        't-1': PlannedSlot(
          start: DateTime(2026, 10, 30, 15),
          end: DateTime(2026, 10, 30, 16, 30),
        ),
      },
    );
    expect(
      find.text('Planned Fri, Oct 30, 3:00 PM – 4:30 PM'),
      findsOneWidget,
    );
  });

  testWidgets('the next planned slot outranks an already-started block', (
    tester,
  ) async {
    await pumpTile(
      tester,
      task(
        schedule: ScheduleFacet(
          due: due,
          start: DateTime(2026, 10, 25, 8),
          end: DateTime(2026, 10, 25, 8, 45),
        ),
      ),
      upcomingEventCounts: const {'t-1': 1},
      plannedSlots: {
        't-1': PlannedSlot(
          start: DateTime(2026, 10, 27, 10),
          end: DateTime(2026, 10, 27, 11),
        ),
      },
    );
    expect(
      find.text('Planned Tue, Oct 27, 10:00 AM – 11:00 AM'),
      findsOneWidget,
    );
  });

  testWidgets('a passed block keeps its day visible', (tester) async {
    // The plan is in the past, so it is not upcoming — the tile still shows
    // when it was planned instead of dropping the line.
    await pumpTile(
      tester,
      task(
        schedule: ScheduleFacet(
          due: DateTime(2026, 10, 26, 23, 59),
          start: DateTime(2026, 10, 25, 8),
          end: DateTime(2026, 10, 25, 9),
        ),
      ),
      upcomingEventCounts: const {},
      plannedSlots: const {},
    );
    expect(find.text('Due Mon, Oct 26'), findsOneWidget);
    expect(find.text('Planned today, 8:00 AM – 9:00 AM'), findsOneWidget);
  });

  testWidgets('cross-midnight plans name both days', (tester) async {
    await pumpTile(
      tester,
      task(schedule: ScheduleFacet(due: due)),
      upcomingEventCounts: const {'t-1': 1},
      plannedSlots: {
        't-1': PlannedSlot(
          start: DateTime(2026, 10, 26, 23),
          end: DateTime(2026, 10, 27, 0, 30),
        ),
      },
    );
    expect(
      find.text('Planned tomorrow, 11:00 PM – Tue, Oct 27, 12:30 AM'),
      findsOneWidget,
    );
  });

  testWidgets('an all-day feed window is not shown as planned work', (
    tester,
  ) async {
    // Learning Suite ships an open..due window; the window's 11:59 PM bounds
    // are dates, not a plan, so the tile keeps the estimate line instead.
    final homework = Node(
      id: 'h-1',
      title: 'Quiz 3',
      createdAt: DateTime(2026, 10, 1),
      sourceEventId: 'e-quiz',
      feedId: 'ls-feed',
      classId: 'ls-feed',
      schedule: ScheduleFacet(
        due: DateTime(2026, 10, 31, 23, 59),
        start: DateTime(2026, 10, 20, 23, 59),
        end: DateTime(2026, 10, 31, 23, 59),
        allDay: true,
      ),
    );
    await pumpTile(
      tester,
      homework,
      upcomingEventCounts: const {},
      plannedSlots: const {},
    );
    expect(find.text('Due Sat, Oct 31'), findsOneWidget);
    expect(find.textContaining('Planned'), findsNothing);
    expect(find.text('Est ~1h'), findsOneWidget);
  });
}
