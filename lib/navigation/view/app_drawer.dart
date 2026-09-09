import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NavigationCubit, PlannerPage>(
      builder: (context, currentPage) {
        return NavigationDrawer(
          selectedIndex: currentPage.index,
          onDestinationSelected: (index) {
            Navigator.of(context).pop();
            context.read<NavigationCubit>().setPage(PlannerPage.values[index]);
          },
          children: const [
            NavigationDrawerDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: Text('Home'),
            ),
            NavigationDrawerDestination(
              icon: Icon(Icons.calendar_month_outlined),
              selectedIcon: Icon(Icons.calendar_month),
              label: Text('Calendar'),
            ),
            NavigationDrawerDestination(
              icon: Icon(Icons.checklist_outlined),
              selectedIcon: Icon(Icons.checklist),
              label: Text('Tasks'),
            ),
            NavigationDrawerDestination(
              icon: Icon(Icons.flag_outlined),
              selectedIcon: Icon(Icons.flag),
              label: Text('Goals'),
            ),
            NavigationDrawerDestination(
              icon: Icon(Icons.bar_chart_outlined),
              selectedIcon: Icon(Icons.bar_chart),
              label: Text('Stats'),
            ),
            NavigationDrawerDestination(
              icon: Icon(Icons.attach_money_outlined),
              selectedIcon: Icon(Icons.attach_money),
              label: Text('Finances'),
            ),
            NavigationDrawerDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: Text('Settings'),
            ),
          ],
        );
      },
    );
  }
}
