import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/auto_goal_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('turning automation on emits a facet and edits its target', (
    tester,
  ) async {
    AutoFacet? value;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: AutoGoalFields(
                value: value,
                classOptions: const ['Physics'],
                activityOptions: const ['Run'],
                moneyCategoryOptions: const ['Food'],
                onChanged: (next) => setState(() => value = next),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Automated goal'), findsOneWidget);
    await tester.tap(find.widgetWithText(SwitchListTile, 'Automated goal'));
    await tester.pump();

    expect(value, isNotNull);
    expect(value!.source, AutoSource.tasks);
    expect(value!.metric, AutoMetric.minutes);
    expect(value!.period, TimeScale.weekly);

    await tester.enterText(find.byType(TextField).first, '420');
    await tester.pump();
    expect(value!.target, 420);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Homework only'));
    await tester.pump();
    expect(value!.homeworkOnly, isTrue);
    expect(value!.scope, AutoScope.all);
    expect(find.text('Classes'), findsOneWidget);
    expect(find.text('Physics'), findsOneWidget);

    // Turning it back off clears the facet rather than leaving a hidden
    // stale configuration on the node.
    await tester.tap(find.widgetWithText(SwitchListTile, 'Automated goal'));
    await tester.pump();
    expect(value, isNull);
  });

  testWidgets('source swap keeps only compatible metrics', (tester) async {
    AutoFacet? value = const AutoFacet(
      source: AutoSource.activities,
      metric: AutoMetric.days,
      target: 5,
      activityTypes: ['Run'],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: AutoGoalFields(
                value: value,
                onChanged: (next) => setState(() => value = next),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Run'), findsOneWidget);
    expect(find.textContaining('Activities (Strava)'), findsWidgets);

    // Switch to money: amount is offered and the stale activity type is
    // irrelevant to the new selector.
    await tester.tap(find.text('Activities (Strava)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Money (transactions)').last);
    await tester.pumpAndSettle();
    expect(value!.source, AutoSource.money);
    expect(value!.metric, AutoMetric.amount);
  });
}
