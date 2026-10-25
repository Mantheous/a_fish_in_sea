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
      source: AutoSource.tasks,
      metric: AutoMetric.percentDone,
      target: 100,
      homeworkOnly: true,
      classKeys: ['Physics'],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: AutoGoalFields(
                value: value,
                classOptions: const ['Physics'],
                onChanged: (next) => setState(() => value = next),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Physics'), findsOneWidget);
    expect(find.textContaining('Tasks & calendar'), findsWidgets);

    // Switch to money: amount is offered and the task-only filters are
    // dropped from the visible form.
    await tester.tap(find.text('Tasks & calendar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Money (transactions)').last);
    await tester.pumpAndSettle();
    expect(value!.source, AutoSource.money);
    expect(value!.metric, AutoMetric.amount);
  });

  testWidgets('class chips render names but keep feeding the raw keys', (
    tester,
  ) async {
    const feedKey = 'feed:1789249594268000';
    AutoFacet? value = const AutoFacet(
      source: AutoSource.tasks,
      metric: AutoMetric.percentDone,
      target: 100,
      homeworkOnly: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: AutoGoalFields(
                value: value,
                classOptions: const [feedKey],
                className: (key) =>
                    key == feedKey ? 'Discrete Structure' : key,
                onChanged: (next) => setState(() => value = next),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Discrete Structure'), findsOneWidget);
    expect(find.text(feedKey), findsNothing);
    expect(find.textContaining('Discrete Structure'), findsWidgets);

    await tester.tap(find.widgetWithText(FilterChip, 'Discrete Structure'));
    await tester.pump();
    expect(value!.classKeys, [feedKey]);
    // The chips kept their raw key while the summary shows the class name.
    expect(find.text(feedKey), findsNothing);
  });
}
