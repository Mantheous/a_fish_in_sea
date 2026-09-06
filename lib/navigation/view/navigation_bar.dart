import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class NavBar extends StatelessWidget {
  const NavBar({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NavigationCubit, PlannerPage>(
      builder: (context, currentPage) {
        final navCubit = context.read<NavigationCubit>();
        return NavigationBar(
          onDestinationSelected: (index) =>
              navCubit.setPage(PlannerPage.values[index]),
          selectedIndex: currentPage.index,
          destinations: const <Widget>[
            NavigationDestination(
              selectedIcon: Icon(Icons.home),
              icon: Icon(Icons.home_outlined),
              label: 'Home',
            ),
            NavigationDestination(
              selectedIcon: Icon(Icons.calendar_month),
              icon: Icon(Icons.calendar_month_outlined),
              label: 'Calendar',
            ),
            NavigationDestination(
              selectedIcon: Icon(Icons.checklist),
              icon: Icon(Icons.checklist_outlined),
              label: 'Tasks',
            ),
            NavigationDestination(
              selectedIcon: Icon(Icons.attach_money),
              icon: Icon(Icons.attach_money_outlined),
              label: 'Finances',
            ),
            NavigationDestination(
              selectedIcon: Icon(Icons.settings),
              icon: Icon(Icons.settings_outlined),
              label: 'Settings',
            ),
          ],
        );
      },
    );
  }
}
