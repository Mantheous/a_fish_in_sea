import 'dart:io';

import 'package:a_fish_in_sea/finances/bloc/expenses_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/view/transaction_history_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:a_fish_in_sea/navigation/view/calendar_page.dart';
import 'package:a_fish_in_sea/finances/view/finances_page.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter/foundation.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  HydratedStorage.build(
    storageDirectory: kIsWeb
        ? HydratedStorage.webStorageDirectory
        : await getApplicationDocumentsDirectory(),
  );

  HydratedBloc.storage = await HydratedStorage.build(
    storageDirectory: Directory("/storage"),
  );

  runApp(
    MultiBlocProvider(
      providers: [
        BlocProvider<NavigationCubit>(create: (context) => NavigationCubit()),
        BlocProvider<ExpensesCubit>(create: (context) => ExpensesCubit()),
        BlocProvider<TransactionsCubit>(
          create: (context) => TransactionsCubit(),
        ),
      ],
      child: const AFishInTheSeaApp(),
    ),
  );
}

class AFishInTheSeaApp extends StatelessWidget {
  const AFishInTheSeaApp({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color.fromARGB(255, 122, 195, 230),
      ),
    );
    context.read<TransactionsCubit>().importCsv();
    return MaterialApp(
      theme: theme,
      home: BlocBuilder<NavigationCubit, int>(
        builder: (context, currentPageIndex) {
          return [
            HomePage(),
            CalendarPage(),
            TransactionHistoryPage(theme: theme),
            FinancesPage(theme: theme),
          ][currentPageIndex];
        },
      ),
    );
  }
}
