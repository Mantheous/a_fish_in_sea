import 'package:a_fish_in_sea/planner/service/weekly_time_report.dart';
import 'package:a_fish_in_sea/reporting/view/time_by_goal_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Goldens for the Stats "Time by goal" card: populated and empty.
/// Regenerate deliberately with:
///   ~/flutter/bin/flutter test test/goldens/time_by_goal_card_test.dart --update-goldens
void main() {
  Future<void> pumpCard(WidgetTester tester, WeeklyTimeReport report) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.teal,
          useMaterial3: true,
          brightness: Brightness.light,
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 380,
              child: TimeByGoalCard(report: report),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('populated card', (tester) async {
    await pumpCard(
      tester,
      WeeklyTimeReport(
        weekTotal: const Duration(hours: 1, minutes: 45),
        byGoal: const [
          WeeklyGoalTotal(
            goalId: 'goal-study',
            title: 'Study goal',
            total: Duration(hours: 1, minutes: 30),
          ),
          WeeklyGoalTotal(
            goalId: null,
            title: '(no goal)',
            total: Duration(minutes: 15),
          ),
        ],
        entries: [
          WeeklyTimeEntry(
            title: 'Math HW',
            goalId: 'goal-study',
            goalTitle: 'Study goal',
            start: DateTime(2026, 9, 8, 9),
            end: DateTime(2026, 9, 8, 9, 45),
          ),
          WeeklyTimeEntry(
            title: 'Reading',
            goalId: 'goal-study',
            goalTitle: 'Study goal',
            start: DateTime(2026, 9, 8, 10),
            end: DateTime(2026, 9, 8, 10, 45),
          ),
          WeeklyTimeEntry(
            title: 'Errand',
            goalId: null,
            goalTitle: '(no goal)',
            start: DateTime(2026, 9, 9, 8),
            end: DateTime(2026, 9, 9, 8, 15),
          ),
        ],
      ),
    );
    await expectLater(
      find.byType(TimeByGoalCard),
      matchesGoldenFile('time_by_goal_card_test.populated.png'),
    );
  });

  testWidgets('empty card', (tester) async {
    await pumpCard(
      tester,
      const WeeklyTimeReport(weekTotal: Duration.zero, byGoal: [], entries: []),
    );
    await expectLater(
      find.byType(TimeByGoalCard),
      matchesGoldenFile('time_by_goal_card_test.empty.png'),
    );
  });
}
