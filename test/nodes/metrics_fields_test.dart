import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/metrics_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('adds multiple metrics, edits targets, and reorders them', (
    tester,
  ) async {
    List<AutoFacet> value = const [];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: MetricsFields(
                value: value,
                hasChildren: false,
                classOptions: const ['Physics'],
                moneyCategoryOptions: const ['Food'],
                onChanged: (next) => setState(() => value = next),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Metrics'), findsOneWidget);
    expect(find.textContaining('checklist goal'), findsOneWidget);

    await tester.tap(find.text('Add metric'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Minutes').last);
    await tester.pumpAndSettle();
    expect(value, hasLength(1));
    expect(value.single.metric, AutoMetric.minutes);

    final target = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Target minutes',
    );
    expect(target, findsOneWidget);
    await tester.enterText(target, '420');
    await tester.pump();
    expect(value.single.target, 420);

    await tester.tap(find.text('Add metric'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All work done').last);
    await tester.pumpAndSettle();
    expect(value, hasLength(2));
    expect(value.last.metric, AutoMetric.allDone);

    // The second metric moves into the primary slot.
    await tester.tap(find.byTooltip('Move up').last);
    await tester.pump();
    expect(value.first.metric, AutoMetric.allDone);
    expect(value.last.metric, AutoMetric.minutes);

    // Removing one leaves the other.
    await tester.tap(find.byTooltip('Remove metric').first);
    await tester.pump();
    expect(value, hasLength(1));
    expect(value.single.metric, AutoMetric.minutes);
  });

  testWidgets('a container gets all-work-done before a cap', (tester) async {
    List<AutoFacet> value = const [];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: MetricsFields(
                value: value,
                hasChildren: true,
                onChanged: (next) => setState(() => value = next),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Add metric'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Minutes').last);
    await tester.pumpAndSettle();
    expect(value.map((m) => m.metric), [
      AutoMetric.allDone,
      AutoMetric.minutes,
    ]);
  });

  testWidgets('source swap keeps only compatible metrics', (tester) async {
    List<AutoFacet> value = const [
      AutoFacet(
        source: AutoSource.tasks,
        metric: AutoMetric.percentDone,
        target: 100,
        homeworkOnly: true,
        classKeys: ['Physics'],
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: MetricsFields(
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
    await tester.tap(find.text('Tasks & calendar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Money (transactions)').last);
    await tester.pumpAndSettle();
    expect(value.single.source, AutoSource.money);
    expect(value.single.metric, AutoMetric.amount);
  });
}
