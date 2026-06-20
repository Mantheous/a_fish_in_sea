import 'package:a_fish_in_sea/calendar/month_calendar.dart';
import 'package:a_fish_in_sea/finances/bloc/budget_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/finances/model/budget.dart';
import 'package:a_fish_in_sea/navigation/view/navigation_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class CalendarPage extends StatelessWidget {
  const CalendarPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: const NavBar(),
      body: SafeArea(
        child: BlocBuilder<WaterfallCubit, WaterfallState>(
          builder: (context, waterfallState) {
            return BlocBuilder<BudgetCubit, List<Budget>>(
              builder: (context, budgets) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(8.0),
                  child: MonthCalendar(
                    entries: waterfallState.rows,
                    budgets: budgets,
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
