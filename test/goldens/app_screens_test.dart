import 'package:a_fish_in_sea/navigation/view/finances_hub.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:a_fish_in_sea/planner/view/tasks_page.dart';
import 'package:a_fish_in_sea/settings/view/settings_page.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_app.dart';

/// Full-screen goldens for the five bottom-nav destinations, empty state.
///
/// These are the cheap deterministic complement to the UX walker's vision
/// passes: any layout/appearance regression fails `flutter test` here
/// instead of reaching a human. Regenerate baselines deliberately with:
///   ~/flutter/bin/flutter test test/goldens --update-goldens
/// and review the diff before committing — a changed golden is guilty
/// until proven intentional.
void main() {
  testWidgets('home empty state', (tester) async {
    await pumpGoldenPage(tester, const HomePage());
    await expectLater(
      find.byType(HomePage),
      matchesGoldenFile('app_screens_test.home.png'),
    );
  });

  testWidgets('calendar empty state', (tester) async {
    await pumpGoldenPage(tester, const CalendarPage());
    await expectLater(
      find.byType(CalendarPage),
      matchesGoldenFile('app_screens_test.calendar.png'),
    );
  });

  testWidgets('tasks empty state', (tester) async {
    await pumpGoldenPage(tester, const TasksPage());
    await expectLater(
      find.byType(TasksPage),
      matchesGoldenFile('app_screens_test.tasks.png'),
    );
  });

  testWidgets('finances hub empty state', (tester) async {
    await pumpGoldenPage(tester, const FinancesHubPage());
    await expectLater(
      find.byType(FinancesHubPage),
      matchesGoldenFile('app_screens_test.finances.png'),
    );
  });

  testWidgets('settings page', (tester) async {
    await pumpGoldenPage(tester, const SettingsPage());
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('app_screens_test.settings.png'),
    );
  });
}
