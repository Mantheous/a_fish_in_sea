import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/navigation/view/finances_hub.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:a_fish_in_sea/nodes/view/nodes_page.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_visibility_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:a_fish_in_sea/planner/view/tasks_page.dart';
import 'package:a_fish_in_sea/reporting/bloc/places_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/tracking_cubit.dart';
import 'package:a_fish_in_sea/reporting/view/stats_page.dart';
import 'package:a_fish_in_sea/settings/view/settings_page.dart';
import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:a_fish_in_sea/sync/sync_meta_cubit.dart';
import 'package:a_fish_in_sea/sync/view/auth_page.dart';
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
            ),
            proxyBase: () =>
                context.read<SettingsCubit>().state.icalProxyBase,
            syncClient: context.read<AuthCubit>().syncClient,
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

/// Boots the sync engine once (first pull if signed in) and runs the
/// 5-minute background timer while the app lives.
class _SyncBootstrap extends StatefulWidget {
  const _SyncBootstrap();

  @override
  State<_SyncBootstrap> createState() => _SyncBootstrapState();
}

class _SyncBootstrapState extends State<_SyncBootstrap> {
  @override
  void initState() {
    super.initState();
    final engine = context.read<SyncEngine>();
    engine.boot();
    engine.startAutoSync();
  }

  @override
  void dispose() {
    context.read<SyncEngine>().stopAutoSync();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
      home: BlocBuilder<AuthCubit, AuthState>(
        builder: (context, auth) {
          if (!auth.isSignedIn) return const AuthPage();
          return BlocBuilder<NavigationCubit, PlannerPage>(
            builder: (context, page) {
              return switch (page) {
                PlannerPage.home => const HomePage(),
                PlannerPage.calendar => const CalendarPage(),
                PlannerPage.tasks => const TasksPage(),
                PlannerPage.nodes => const NodesPage(),
                PlannerPage.stats => const StatsPage(),
                PlannerPage.finances => const FinancesHubPage(),
                PlannerPage.settings => const SettingsPage(),
              };
            },
          );
        },
      ),
    );
  }
}
