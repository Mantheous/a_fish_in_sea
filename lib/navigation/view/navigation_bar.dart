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
            icon: Icon(Icons.calendar_month),
            label: 'Calendar',
          ),
          NavigationDestination(
            icon: Icon(Icons.insert_chart_outlined),
            label: 'Transaction History',
          ),
          NavigationDestination(
            icon: Icon(Icons.monetization_on_outlined),
            label: 'Goals',
          ),
        ],
      );
    });
    
  }

}