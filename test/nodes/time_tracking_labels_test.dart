import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/node_finish_sheet.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_visibility_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/tasks_tab_cubit.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/reporting/bloc/places_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/tracking_cubit.dart';
import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

class MockClient extends Mock implements http.Client {}

class MockGoogleService extends Mock implements GoogleCalendarService {}

void _useMockStorage() {
  final storage = MockStorage();
  when(() => storage.read(any())).thenReturn(null);
  when(() => storage.write(any(), any())).thenAnswer((_) async {});
  when(() => storage.delete(any())).thenAnswer((_) async {});
  when(() => storage.clear()).thenAnswer((_) async {});
  HydratedBloc.storage = storage;
}

/// Pumps [page] inside the real provider graph (mirrors
/// test/goldens/golden_app.dart) and returns the cubits the test may
/// need to seed. Run under runAsync: HomePage starts FeedCubit's
/// auto-resync timer, which must not trip the fake-async invariant.
Future<NodeCubit> pumpTestPage(WidgetTester tester, Widget page) async {
  _useMockStorage();
  final undo = UndoCubit();
  final navigation = NavigationCubit();
  final settings = SettingsCubit();
  final syncClient = SyncClient(
    serverBase: () => 'http://localhost:1',
    accessToken: () => null,
    refreshAccessToken: () async => null,
    client: MockClient(),
  );
  final auth = AuthCubit(client: () => syncClient);
  final nodes = NodeCubit();
  final transactions = TransactionsCubit();
  final plaid = PlaidCubit();
  final waterfall = WaterfallCubit(
    nodeCubit: nodes,
    transactionsCubit: transactions,
    plaidCubit: plaid,
  );
  final events = CalendarCubit();
  final visibility = CalendarVisibilityCubit();
  final drafts = CalendarDraftCubit();
  final tasksTab = TasksTabCubit();
  final places = PlacesCubit();
  final tracking = TrackingCubit();
  final reporting = ReportingCubit();
  final feeds = FeedCubit(
    calendarCubit: events,
    nodeCubit: nodes,
    icalService: IcalService(client: MockClient()),
    googleService: MockGoogleService(),
    proxyBase: () => 'http://localhost:1',
    syncClient: syncClient,
  );
  final closables = [
    feeds,
    reporting,
    tracking,
    places,
    tasksTab,
    drafts,
    visibility,
    events,
    waterfall,
    plaid,
    transactions,
    nodes,
    auth,
    settings,
    navigation,
    undo,
  ];
  addTearDown(() async {
    await tester.pumpWidget(Container());
    for (final c in closables) {
      await c.close();
    }
  });
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<UndoCubit>.value(value: undo),
          BlocProvider<NavigationCubit>.value(value: navigation),
          BlocProvider<SettingsCubit>.value(value: settings),
          BlocProvider<AuthCubit>.value(value: auth),
          BlocProvider<NodeCubit>.value(value: nodes),
          BlocProvider<TransactionsCubit>.value(value: transactions),
          BlocProvider<PlaidCubit>.value(value: plaid),
          BlocProvider<WaterfallCubit>.value(value: waterfall),
          BlocProvider<CalendarCubit>.value(value: events),
          BlocProvider<CalendarVisibilityCubit>.value(value: visibility),
          BlocProvider<CalendarDraftCubit>.value(value: drafts),
          BlocProvider<TasksTabCubit>.value(value: tasksTab),
          BlocProvider<PlacesCubit>.value(value: places),
          BlocProvider<TrackingCubit>.value(value: tracking),
          BlocProvider<ReportingCubit>.value(value: reporting),
          BlocProvider<FeedCubit>.value(value: feeds),
        ],
        child: MaterialApp(home: Scaffold(body: page)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(seconds: 1));
  });
  return nodes;
}

void main() {
  testWidgets('idle scheduled row shows the planned line exactly once',
      (tester) async {
    final now = DateTime.now();
    final nodes = await pumpTestPage(tester, const HomePage());
    await tester.runAsync(() async {
      nodes.addNode(Node(
        id: 'node:track-1',
        title: 'Focus block',
        createdAt: now.subtract(const Duration(days: 1)),
        schedule: ScheduleFacet(
          start: now.subtract(const Duration(hours: 1)),
          end: now.add(const Duration(hours: 1)),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    });

    expect(find.text('Happening now'), findsOneWidget);
    // The planned line used to render twice (subtitle + status fallback).
    expect(find.textContaining('Planned '), findsOneWidget);
    // And an idle row reports nothing.
    expect(find.textContaining('Reported '), findsNothing);
    expect(find.textContaining('Recording '), findsNothing);
  });

  testWidgets('finish sheet explains sub-minute sessions and goal actions',
      (tester) async {
    final end = DateTime(2026, 10, 11, 8, 53, 4);
    final nodes = await pumpTestPage(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              showNodeFinishSheet(context, nodeId: 'node:quick'),
          child: const Text('open'),
        ),
      ),
    );
    await tester.runAsync(() async {
      nodes.addNode(Node(
        id: 'node:quick',
        title: 'Quick check',
        createdAt: DateTime(2026, 10, 11),
        actualStart: end.subtract(const Duration(seconds: 4)),
        actualEnd: end,
      ));
      await tester.pump();
    });

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // A 4-second session keeps seconds instead of printing "(0m)".
    expect(find.textContaining('(0m)'), findsNothing);
    expect(find.textContaining('(4s)'), findsOneWidget);
    // The actions clearly change the goal, not just the session.
    expect(find.text('Mark goal complete'), findsOneWidget);
    expect(find.text('Mark goal failed'), findsOneWidget);
    expect(find.textContaining("goal's status"), findsOneWidget);
    // The safe exit stays visible.
    expect(find.text('Not now'), findsOneWidget);
  });
}
