import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../demo/demo_banner.dart';
import '../../demo/demo_cubit.dart';
import '../../feedback/view/feedback_page.dart';
import '../../navigation/bloc/navigation_cubit.dart';
import '../../nodes/view/nodes_page.dart';
import '../../planner/view/calendar_page.dart';
import '../../planner/view/tasks_page.dart';
import '../../reporting/view/stats_page.dart';
import '../../settings/view/settings_page.dart';
import 'finances_hub.dart';
import 'home_page.dart';

/// The signed-in application: one page per navigation tab, with the demo
/// banner pinned above everything while demo mode is active.
///
/// Lives outside `main.dart` so the auth gate can keep the shell mounted
/// underneath the falling wave.
class PlannerShell extends StatelessWidget {
  const PlannerShell({super.key});

  @override
  Widget build(BuildContext context) {
    final demo = context.watch<DemoCubit>().state;
    final content = BlocBuilder<NavigationCubit, PlannerPage>(
      builder: (context, page) {
        return switch (page) {
          PlannerPage.home => const HomePage(),
          PlannerPage.calendar => const CalendarPage(),
          PlannerPage.tasks => const TasksPage(),
          PlannerPage.nodes => const NodesPage(),
          PlannerPage.stats => const StatsPage(),
          PlannerPage.finances => const FinancesHubPage(),
          PlannerPage.feedback => const FeedbackPage(),
          PlannerPage.settings => const SettingsPage(),
        };
      },
    );
    if (!demo) return content;
    // Demo shell: persistent mock-data banner above every page.
    // Inner pages keep their own Scaffolds (drawers keep working).
    return Scaffold(
      body: Column(
        children: [
          const DemoBanner(),
          Expanded(child: content),
        ],
      ),
    );
  }
}
