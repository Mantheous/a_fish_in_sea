import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class NavBar extends StatelessWidget {
  const NavBar({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NavigationCubit, int>(builder: (context, currentPageIndex) {
      final navCubit = context.read<NavigationCubit>();
      return NavigationBar(
        onDestinationSelected: (index) => navCubit.setPage(index),
        indicatorColor: Colors.amber,
        selectedIndex: currentPageIndex,
        destinations: const <Widget>[
          NavigationDestination(
            selectedIcon: Icon(Icons.home),
            icon: Icon(Icons.home_outlined),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.waterfall_chart),
            label: 'Waterfall',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune),
            label: 'Rules & Budgets',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance),
            label: 'Bank',
          ),
          NavigationDestination(
            selectedIcon: Icon(Icons.calendar_month),
            icon: Icon(Icons.calendar_month_outlined),
            label: 'Calendar',
          ),
        ],
      );
    });
  }
}