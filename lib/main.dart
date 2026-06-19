import 'package:a_fish_in_sea/finances/bloc/budget_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/expense_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/recurring_rules_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/finances/view/plaid_link_page.dart';
import 'package:a_fish_in_sea/finances/view/rules_and_budgets_page.dart';
import 'package:a_fish_in_sea/finances/view/waterfall_ledger_page.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
        BlocProvider(create: (_) => NavigationCubit()),
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
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Waterfall Ledger',
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
        home: BlocBuilder<NavigationCubit, int>(
          builder: (context, page) {
            switch (page) {
              case 0:
                return const HomePage();
              case 1:
                return const WaterfallLedgerPage();
              case 2:
                return const RulesAndBudgetsPage();
              case 3:
                return const PlaidLinkPage();
              default:
                return const HomePage();
            }
          },
        ),
      ),
    );
  }
}
