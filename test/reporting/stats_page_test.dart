import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/assignment_estimates_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/assignment_rules_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_visibility_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/model/assignment_rule.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/reporting/bloc/places_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/tracking_cubit.dart';
import 'package:a_fish_in_sea/reporting/view/stats_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

class MockGoogleService extends Mock implements GoogleCalendarService {}

/// A monday-anchored set of fixtures so the "this week" range is stable.
final _monday = DateTime.now().subtract(
  Duration(days: DateTime.now().weekday - 1),
);

DateTime _at(int dayOffset, int hour, [int minute = 0]) =>
    _monday.add(Duration(days: dayOffset, hours: hour, minutes: minute));

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  testWidgets('stats page shows time by class, by type and the goal list',
      (tester) async {
    final rulesCubit = AssignmentRulesCubit();
    rulesCubit.upsertRule(AssignmentRule(
      id: 'r1',
      feedId: 'math290',
      templateKey: 'video quiz',
      displayName: 'Video Quiz',
      dueOffsetDays: -2,
      estimateMinutes: 45,
      createdAt: DateTime.now(),
    ));

    final nodeCubit = NodeCubit()
      ..addNode(Node(
        id: 'n:quiz',
        title: 'Video Quiz 3.1',
        createdAt: _monday,
        feedId: 'math290',
        classId: 'math290',
        classLabel: 'MATH 290',
        sourceEventId: 'evt:quiz',
        schedule: ScheduleFacet(due: _at(2, 23)),
        actualStart: _at(1, 19),
        actualEnd: _at(1, 19).add(const Duration(minutes: 45)),
      ))
      ..addNode(Node(
        id: 'n:problem',
        title: 'Problem Set 5',
        createdAt: _monday,
        feedId: 'stat230',
        classId: 'stat230',
        classLabel: 'STAT 230',
        sourceEventId: 'evt:ps',
        schedule: ScheduleFacet(due: _at(3, 23)),
        actualStart: _at(2, 9),
        actualEnd: _at(2, 9).add(const Duration(minutes: 90)),
      ))
      ..addNode(Node(
        id: 'n:goal',
        title: 'Run a 10k',
        createdAt: _monday,
        status: NodeStatus.done,
        completedAt: _at(2, 18),
      ))
      ..addNode(Node(
        id: 'n:gym',
        title: 'Lift',
        createdAt: _monday,
        effort: const EffortFacet(targetMinutes: 180),
      ));

    tester.view.physicalSize = const Size(900, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider(create: (_) => UndoCubit()),
          BlocProvider(create: (_) => SettingsCubit()),
          BlocProvider(create: (_) => CalendarCubit()),
          BlocProvider(create: (_) => CalendarVisibilityCubit()),
          BlocProvider(create: (_) => CalendarDraftCubit()),
          BlocProvider(
            create: (_) => FeedCubit(
              calendarCubit: CalendarCubit(),
              nodeCubit: nodeCubit,
              icalService: IcalService(),
              googleService: MockGoogleService(),
              proxyBase: () => '',
            ),
          ),
          BlocProvider.value(value: rulesCubit),
          BlocProvider(create: (_) => AssignmentEstimatesCubit()),
          BlocProvider.value(value: nodeCubit),
          BlocProvider(create: (_) => PlacesCubit()),
          BlocProvider(create: (_) => TrackingCubit()),
          BlocProvider(create: (_) => ReportingCubit()),
        ],
        child: const MaterialApp(home: StatsPage()),
      ),
    );
    await tester.pumpAndSettle();

    // The range picker and every section are present.
    expect(find.text('This week'), findsOneWidget);
    expect(find.text('Time by class'), findsOneWidget);
    expect(find.text('Time by assignment type'), findsOneWidget);
    expect(find.text('Goals'), findsOneWidget);

    // Recorded assignment time is 45 + 90 = 135 minutes.
    expect(find.text('2h 15m'), findsOneWidget);
    expect(find.text('recorded'), findsOneWidget);

    // Both classes appear with their minutes.
    expect(find.text('MATH 290'), findsOneWidget);
    expect(find.text('STAT 230'), findsOneWidget);

    // The classified type, not the raw titles.
    expect(find.text('Video Quiz'), findsOneWidget);

    // Goals: finished this week plus the open time goal.
    expect(find.text('Run a 10k'), findsOneWidget);
    expect(find.text('1 finished'), findsOneWidget);
    expect(find.text('Time goal'), findsOneWidget);
    // Nothing has been recorded against the time goal yet.
    expect(find.textContaining('of 3h'), findsOneWidget);

    // Unaccounted time is reported rather than hidden.
    expect(find.text('not accounted for'), findsOneWidget);
  });
}
