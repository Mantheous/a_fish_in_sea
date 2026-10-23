import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/demo/demo_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/navigation/view/planner_shell.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/service/recurring_goal_coordinator.dart';
import 'package:a_fish_in_sea/nodes/bloc/schedule_prefs_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_panel_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_visibility_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/tasks_tab_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/assignment_estimates_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/assignment_rules_cubit.dart';
import 'package:a_fish_in_sea/planner/model/assignment_rule.dart';
import 'package:a_fish_in_sea/planner/bloc/tasks_view_options_cubit.dart';
import 'package:a_fish_in_sea/planner/service/canvas_service.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/reporting/bloc/places_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/tracking_cubit.dart';
import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:a_fish_in_sea/sync/sync_meta_cubit.dart';
import 'package:a_fish_in_sea/sync/view/auth/auth_gate.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  HydratedBloc.storage = await HydratedStorage.build(
    storageDirectory: kIsWeb
        ? HydratedStorage.webStorageDirectory
        : await getApplicationDocumentsDirectory(),
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => UndoCubit(), lazy: false),
        // Demo mode is intentionally NOT hydrated: it must never persist.
        BlocProvider(create: (_) => DemoCubit()),
        BlocProvider(create: (_) => NavigationCubit()),
        BlocProvider(create: (_) => SettingsCubit()),
        // Auth owns the sync-server identity. The SyncClient closure reads
        // Settings/Auth state lazily (same pattern as FeedCubit.proxyBase).
        BlocProvider(create: (context) {
          AuthCubit? ref;
          final client = SyncClient(
            serverBase: () =>
                context.read<SettingsCubit>().state.icalProxyBase,
            accessToken: () => ref?.state.accessToken,
            refreshAccessToken: () =>
                ref?.refreshAccessToken() ?? Future.value(null),
          );
          ref = AuthCubit(client: () => client);
          SyncAuth.tokenProvider = () => ref?.state.accessToken;
          SyncAuth.refreshProvider =
              () => ref?.refreshAccessToken() ?? Future.value(null);
          return ref;
        }),
        BlocProvider(create: (_) => SyncMetaCubit()),
        BlocProvider(create: (_) => NodeCubit()),
        BlocProvider(create: (_) => TransactionsCubit()),
        BlocProvider(create: (_) => PlaidCubit()),
        BlocProvider(
          create: (context) => WaterfallCubit(
            nodeCubit: context.read<NodeCubit>(),
            transactionsCubit: context.read<TransactionsCubit>(),
            plaidCubit: context.read<PlaidCubit>(),
          ),
        ),
        BlocProvider(create: (_) => CalendarCubit()),
        BlocProvider(create: (_) => CalendarVisibilityCubit()),
        BlocProvider(create: (_) => CalendarDraftCubit()),
        BlocProvider(create: (_) => TasksTabCubit()),
        BlocProvider(create: (_) => CalendarPanelCubit()),
        BlocProvider(create: (_) => SchedulePrefsCubit()),
        BlocProvider(create: (_) => AssignmentRulesCubit()),
        BlocProvider(create: (_) => AssignmentEstimatesCubit(), lazy: false),
        BlocProvider(create: (_) => TasksViewOptionsCubit()),
        BlocProvider(create: (_) => PlacesCubit()),
        BlocProvider(create: (_) => TrackingCubit()),
        BlocProvider(create: (_) => ReportingCubit()),
        BlocProvider(
          create: (context) => FeedCubit(
            calendarCubit: context.read<CalendarCubit>(),
            nodeCubit: context.read<NodeCubit>(),
            icalService: IcalService(),
            googleService: GoogleCalendarService(
              baseUrl: () =>
                  context.read<SettingsCubit>().state.icalProxyBase,
              userId: () => context.read<PlaidCubit>().state.userId,
              authToken: () =>
                  context.read<AuthCubit>().state.accessToken,
              refreshAccessToken: () =>
                  context.read<AuthCubit>().refreshAccessToken(),
            ),
            proxyBase: () =>
                context.read<SettingsCubit>().state.icalProxyBase,
            syncClient: context.read<AuthCubit>().syncClient,
            assignmentRulesProvider: () {
              try {
                return context.read<AssignmentRulesCubit>().state;
              } catch (_) {
                return const <AssignmentRule>[];
              }
            },
            estimatesCubit: context.read<AssignmentEstimatesCubit>(),
            canvasService: CanvasService(
              baseUrl: () =>
                  context.read<SettingsCubit>().state.icalProxyBase,
              userId: () => context.read<PlaidCubit>().state.userId,
              authToken: () =>
                  context.read<AuthCubit>().state.accessToken,
              refreshAccessToken: () =>
                  context.read<AuthCubit>().refreshAccessToken(),
            ),
          ),
        ),
        RepositoryProvider(
          create: (context) => SyncEngine(
            client: context.read<AuthCubit>().syncClient,
            auth: context.read<AuthCubit>(),
            meta: context.read<SyncMetaCubit>(),
            events: context.read<CalendarCubit>(),
            feeds: context.read<FeedCubit>(),
            nodes: context.read<NodeCubit>(),
            transactions: context.read<TransactionsCubit>(),
            places: context.read<PlacesCubit>(),
            reporting: context.read<ReportingCubit>(),
            tracking: context.read<TrackingCubit>(),
            settings: context.read<SettingsCubit>(),
            waterfall: context.read<WaterfallCubit>(),
            plaid: context.read<PlaidCubit>(),
          ),
        ),
      ],
      child: const _SyncBootstrap(),
    );
  }
}

/// Boots the sync engine once (first pull if signed in) and keeps it live:
/// the 5-minute background timer plus a debounced sync on local mutations.
class _SyncBootstrap extends StatefulWidget {
  const _SyncBootstrap();

  @override
  State<_SyncBootstrap> createState() => _SyncBootstrapState();
}

class _SyncBootstrapState extends State<_SyncBootstrap> {
  // Saved in initState: context.read in dispose() is unsafe once the
  // element is deactivated (crashed test teardown and hot restart).
  SyncEngine? _engine;
  RecurringGoalCoordinator? _goalLinks;

  /// Feed ids seen on the last node/feed change, so a removed class can
  /// be dropped from the learned assignment data.
  bool _estimatesScheduled = false;

  /// The learned effort index is derived data over the whole node list, so
  /// rebuilding it synchronously on every checkbox tap puts O(N) work on
  /// the tap's UI frame (phone hang on check-off). Coalesce rapid edits
  /// into one post-frame rebuild: the tap paints first, estimates land a
  /// frame later. Idempotent pure function, so coalescing loses nothing.
  void _scheduleEstimatesRebuild() {
    if (_estimatesScheduled) return;
    _estimatesScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _estimatesScheduled = false;
      if (!mounted) return;
      try {
        context
            .read<AssignmentEstimatesCubit>()
            .rebuildFrom(context.read<NodeCubit>().state);
      } catch (_) {}
    });
  }

  @override
  void initState() {
    super.initState();
    _goalLinks = RecurringGoalCoordinator(context.read<NodeCubit>(),
        context.read<CalendarCubit>(), context.read<TransactionsCubit>());
    _engine = context.read<SyncEngine>();
    _engine!.boot();
    _engine!.startAutoSync();
    _engine!.startAutoSyncOnChanges();
  }

  @override
  void dispose() {
    _goalLinks?.dispose();
    _engine?.stopAutoSyncOnChanges();
    _engine?.stopAutoSync();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep the learned "how long does this kind of assignment take, and
    // when do I usually start it" index in step with the node list. The
    // rebuild is a pure function of the nodes, so it is idempotent and
    // safe to run on every change.
    return MultiBlocListener(
      listeners: [
        BlocListener<NodeCubit, List<Node>>(
          listenWhen: (a, b) => !identical(a, b),
          listener: (context, nodes) {
            _scheduleEstimatesRebuild();
          },
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'a fish in sea',
        theme: ThemeData(
          colorSchemeSeed: Colors.teal,
          useMaterial3: true,
          brightness: Brightness.light,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.teal,
          useMaterial3: true,
          brightness: Brightness.dark,
        ),
        home: const AuthGate(child: PlannerShell()),
      ),
    );
  }
}
