import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_panel_cubit.dart';
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
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:a_fish_in_sea/sync/sync_meta_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

class MockClient extends Mock implements http.Client {}

class MockGoogleService extends Mock implements GoogleCalendarService {}

/// Pumps [page] inside the real provider graph (mirrors MyApp in main.dart)
/// with empty in-memory state, on a 1280x720 surface. Returns the
/// [SyncEngine] so tests can drive sync-only state (e.g. the data-loss
/// protection banner in Settings → Sync).
///
/// Deliberately skips _SyncBootstrap: no boot(), no auto-sync timer, no
/// network. FeedCubit starts with zero feeds so HomePage's syncAll() is a
/// no-op. All cubits are closed in tearDown so no Timer is left pending.
Future<SyncEngine> pumpGoldenPage(WidgetTester tester, Widget page) async {
  final storage = MockStorage();
  when(() => storage.read(any())).thenReturn(null);
  when(() => storage.write(any(), any())).thenAnswer((_) async {});
  when(() => storage.delete(any())).thenAnswer((_) async {});
  when(() => storage.clear()).thenAnswer((_) async {});
  HydratedBloc.storage = storage;

  // mocktail needs concrete instances to build argument matchers for the
  // stubbed http client below.
  registerFallbackValue(Uri.parse('http://localhost:1'));
  registerFallbackValue(const <String, String>{});

  final mockClient = MockClient();
  // Golden pages render offline: any page that calls the server on pump
  // gets a harmless empty response instead of a null transport response.
  when(() => mockClient.get(captureAny(), headers: captureAny(named: 'headers')))
      .thenAnswer((invocation) async {
    final url = invocation.positionalArguments.first as Uri;
    final body = url.path.endsWith('/status') ? '{}' : '[]';
    return http.Response(body, 200);
  });
  final syncClient = SyncClient(
    serverBase: () => 'http://localhost:1',
    accessToken: () => null,
    refreshAccessToken: () async => null,
    client: mockClient,
  );

  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;

  final undo = UndoCubit();
  final navigation = NavigationCubit();
  final settings = SettingsCubit();
  final auth = AuthCubit(client: () => syncClient);
  final meta = SyncMetaCubit();
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
  final calendarPanel = CalendarPanelCubit();
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
  final engine = SyncEngine(
    client: syncClient,
    auth: auth,
    meta: meta,
    events: events,
    feeds: feeds,
    nodes: nodes,
    transactions: transactions,
    places: places,
    reporting: reporting,
    tracking: tracking,
    settings: settings,
    waterfall: waterfall,
    plaid: plaid,
  );

  // SyncEngine is a plain object (no timers unless booted, and we never
  // boot it here), so it needs no close — everything else does.
  final closables = [
    feeds,
    reporting,
    tracking,
    places,
    tasksTab,
    calendarPanel,
    drafts,
    visibility,
    events,
    waterfall,
    plaid,
    transactions,
    nodes,
    meta,
    auth,
    settings,
    navigation,
    undo,
  ];

  addTearDown(() async {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pumpWidget(Container());
    for (final c in closables) {
      await c.close();
    }
  });

  // Run the pumps on the real async zone: HomePage starts FeedCubit's
  // 15-minute auto-resync timer, which is pending for the app's whole
  // lifetime by design. Inside runAsync it is a real timer, invisible to
  // the fake-async pending-timer invariant, instead of a test failure.
  // tearDown still closes every cubit.
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<UndoCubit>.value(value: undo),
          BlocProvider<NavigationCubit>.value(value: navigation),
          BlocProvider<SettingsCubit>.value(value: settings),
          BlocProvider<AuthCubit>.value(value: auth),
          BlocProvider<SyncMetaCubit>.value(value: meta),
          BlocProvider<NodeCubit>.value(value: nodes),
          BlocProvider<TransactionsCubit>.value(value: transactions),
          BlocProvider<PlaidCubit>.value(value: plaid),
          BlocProvider<WaterfallCubit>.value(value: waterfall),
          BlocProvider<CalendarCubit>.value(value: events),
          BlocProvider<CalendarVisibilityCubit>.value(value: visibility),
          BlocProvider<CalendarDraftCubit>.value(value: drafts),
          BlocProvider<TasksTabCubit>.value(value: tasksTab),
          BlocProvider<CalendarPanelCubit>.value(value: calendarPanel),
          BlocProvider<PlacesCubit>.value(value: places),
          BlocProvider<TrackingCubit>.value(value: tracking),
          BlocProvider<ReportingCubit>.value(value: reporting),
          BlocProvider<FeedCubit>.value(value: feeds),
          RepositoryProvider<SyncEngine>.value(value: engine),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorSchemeSeed: Colors.teal,
            useMaterial3: true,
            brightness: Brightness.light,
          ),
          home: Scaffold(body: page),
        ),
      ),
    );
    // Settle one-shot rebuild timers (e.g. WaterfallCubit's 50ms debounce)
    // without waiting out periodic timers, which are cancelled on close.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(seconds: 1));
  });
  return engine;
}
