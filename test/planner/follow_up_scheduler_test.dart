import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/node_finish_sheet.dart';
import 'package:a_fish_in_sea/planner/bloc/assignment_estimates_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/assignment_rules_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  Future<void> pumpFollowUpButton(
    WidgetTester tester, {
    required NodeCubit nodeCubit,
    required CalendarDraftCubit draftCubit,
    required NavigationCubit navigationCubit,
    required String nodeId,
  }) async {
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider.value(value: nodeCubit),
          BlocProvider.value(value: draftCubit),
          BlocProvider.value(value: navigationCubit),
          BlocProvider(create: (_) => AssignmentRulesCubit()),
          BlocProvider(create: (_) => AssignmentEstimatesCubit()),
          BlocProvider(create: (_) => SettingsCubit()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showFollowUpScheduler(
                  context,
                  nodeId: nodeId,
                ),
                child: const Text('Follow up'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
      'follow-up requests a calendar draft one day after the current block '
      'and navigates to the calendar without saving', (tester) async {
    final nodeCubit = NodeCubit();
    final draftCubit = CalendarDraftCubit();
    final navigationCubit = NavigationCubit();
    final blockStart = DateTime.now()
        .add(const Duration(days: 1))
        .copyWith(hour: 14, minute: 0, second: 0, millisecond: 0);
    final blockEnd = blockStart.add(const Duration(hours: 1));
    nodeCubit.addNode(
      Node(
        id: 'node:follow1',
        title: 'Write report',
        createdAt: DateTime(2026),
        schedule: ScheduleFacet(start: blockStart, end: blockEnd),
      ),
    );

    await pumpFollowUpButton(
      tester,
      nodeCubit: nodeCubit,
      draftCubit: draftCubit,
      navigationCubit: navigationCubit,
      nodeId: 'node:follow1',
    );

    await tester.tap(find.text('Follow up'));
    await tester.pumpAndSettle();

    final seed = draftCubit.state;
    expect(seed, isNotNull);
    expect(seed!.id, calendarDraftEventId);
    expect(seed.taskId, 'node:follow1');
    expect(seed.subject, 'Write report');
    expect(seed.start, blockStart.add(const Duration(days: 1)));
    expect(seed.end, blockEnd.add(const Duration(days: 1)));
    expect(navigationCubit.state, PlannerPage.calendar);
    // Nothing is saved until the user presses Add on the calendar.
    final node = nodeCubit.byId('node:follow1');
    expect(node?.schedule?.start, blockStart);
    expect(node?.schedule?.end, blockEnd);
    expect(
      find.text(
        'Pick a time on the calendar — nothing is saved until you press Add.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('follow-up without a block falls back to the estimate flow',
      (tester) async {
    final nodeCubit = NodeCubit();
    final draftCubit = CalendarDraftCubit();
    final navigationCubit = NavigationCubit();
    final due = DateTime.now().add(const Duration(days: 3));
    final dueDay = DateTime(due.year, due.month, due.day, 23, 59);
    nodeCubit.addNode(
      Node(
        id: 'node:follow2',
        title: 'Read chapter',
        createdAt: DateTime(2026),
        schedule: ScheduleFacet(due: dueDay),
      ),
    );

    await pumpFollowUpButton(
      tester,
      nodeCubit: nodeCubit,
      draftCubit: draftCubit,
      navigationCubit: navigationCubit,
      nodeId: 'node:follow2',
    );

    await tester.tap(find.text('Follow up'));
    await tester.pumpAndSettle();

    final seed = draftCubit.state;
    expect(seed, isNotNull);
    expect(seed!.taskId, 'node:follow2');
    expect(seed.start, DateTime(dueDay.year, dueDay.month, dueDay.day, 12));
    expect(seed.end, DateTime(dueDay.year, dueDay.month, dueDay.day, 13));
    expect(navigationCubit.state, PlannerPage.calendar);
  });
}
