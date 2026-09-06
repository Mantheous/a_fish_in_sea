import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/budget_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/expense_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/recurring_rules_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/navigation/view/finances_hub.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/task_cubit.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:a_fish_in_sea/planner/view/tasks_page.dart';
import 'package:a_fish_in_sea/settings/view/settings_page.dart';
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
        BlocProvider(create: (_) => RecurringRulesCubit()),
        BlocProvider(create: (_) => BudgetCubit()),
        BlocProvider(create: (_) => ExpenseCubit()),
        BlocProvider(create: (_) => TransactionsCubit()),
        BlocProvider(create: (_) => PlaidCubit()),
        BlocProvider(
          create: (context) => WaterfallCubit(
            recurringRulesCubit: context.read<RecurringRulesCubit>(),
            budgetCubit: context.read<BudgetCubit>(),
            expenseCubit: context.read<ExpenseCubit>(),
            transactionsCubit: context.read<TransactionsCubit>(),
            plaidCubit: context.read<PlaidCubit>(),
          ),
        ),
        BlocProvider(create: (_) => CalendarCubit()),
        BlocProvider(create: (_) => CalendarDraftCubit()),
        BlocProvider(create: (_) => TaskCubit()),
        BlocProvider(
          create: (context) => FeedCubit(
            calendarCubit: context.read<CalendarCubit>(),
            taskCubit: context.read<TaskCubit>(),
            icalService: IcalService(),
            googleService: GoogleCalendarService(
              baseUrl: () =>
                  context.read<SettingsCubit>().state.icalProxyBase,
              userId: () => context.read<PlaidCubit>().state.userId,
            ),
            proxyBase: () =>
                context.read<SettingsCubit>().state.icalProxyBase,
          ),
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
        home: BlocBuilder<NavigationCubit, PlannerPage>(
          builder: (context, page) {
            return switch (page) {
              PlannerPage.home => const HomePage(),
              PlannerPage.calendar => const CalendarPage(),
              PlannerPage.tasks => const TasksPage(),
              PlannerPage.finances => const FinancesHubPage(),
              PlannerPage.settings => const SettingsPage(),
            };
          },
        ),
      ),
    );
  }
}
