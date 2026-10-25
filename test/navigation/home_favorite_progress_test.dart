import 'package:a_fish_in_sea/navigation/view/favorite_goal_line.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/node_checkbox.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../goldens/golden_app.dart';

final _created = DateTime(2026, 10, 12, 9);

/// A seeded node is never part of the time-tracking card's unscheduled
/// picks, so favorite rows stay the only checkbox/progress widgets on the
/// page under test.
Node _node(
  String id, {
  String? title,
  List<String> parents = const [],
  bool favorite = false,
  bool done = false,
  DateTime? completedAt,
  AutoFacet? auto,
  MoneyFacet? money,
  bool unbounded = false,
}) => Node(
  id: id,
  title: title ?? id,
  parentIds: parents,
  createdAt: _created,
  isFavorite: favorite,
  isTracked: false,
  isUnbounded: unbounded,
  status: done ? NodeStatus.done : NodeStatus.open,
  completedAt: completedAt,
  auto: auto,
  money: money,
);

Future<void> _pumpHome(WidgetTester tester, List<Node> nodes) async {
  final engine = await pumpGoldenPage(tester, const HomePage());
  await tester.runAsync(() async {
    engine.nodes.emitSilent(nodes);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  });
  expect(tester.takeException(), isNull);
}

double _barValue(WidgetTester tester) {
  final bar = tester.widget<LinearProgressIndicator>(
    find.byType(LinearProgressIndicator),
  );
  return bar.value!;
}

void main() {
  testWidgets('plain favorite keeps its checkbox and adds no bar', (
    tester,
  ) async {
    await _pumpHome(tester, [
      _node('plain', title: 'Call mom', favorite: true),
    ]);

    expect(find.byType(FavoriteGoalLine), findsOneWidget);
    expect(find.byType(NodeCheckbox), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('automated favorite reports progress instead of a checkbox', (
    tester,
  ) async {
    final now = DateTime.now();
    await _pumpHome(tester, [
      _node(
        'auto',
        title: 'Finish assignments',
        favorite: true,
        auto: const AutoFacet(
          metric: AutoMetric.count,
          target: 4,
        ),
      ),
      _node('a1', parents: const ['auto'], done: true, completedAt: now),
      _node('a2', parents: const ['auto'], done: true, completedAt: now),
      _node('a3', parents: const ['auto']),
      _node('a4', parents: const ['auto']),
    ]);

    expect(find.byType(FavoriteGoalLine), findsOneWidget);
    // Measured goal: no checkbox, a bar in its place, actual vs target.
    expect(find.byType(NodeCheckbox), findsNothing);
    expect(_barValue(tester), 0.5);
    expect(find.textContaining('2 / 4'), findsOneWidget);
    expect(find.textContaining('50%'), findsOneWidget);
  });

  testWidgets('favorite with subgoals shows rolled-up progress', (
    tester,
  ) async {
    await _pumpHome(tester, [
      _node('parent', title: 'Learn Spanish', favorite: true),
      _node('child1', parents: const ['parent'], done: true),
      _node('child2', parents: const ['parent']),
    ]);

    // A container's completion is derived from its children, so it no
    // longer carries a manual checkbox; the rolled-up average stays.
    expect(find.byType(NodeCheckbox), findsNothing);
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
    expect(_barValue(tester), 0.5);
    expect(find.textContaining('2 steps'), findsOneWidget);
    expect(find.textContaining('50%'), findsOneWidget);
  });

  testWidgets('money favorite shows reported amount and progress', (
    tester,
  ) async {
    await _pumpHome(tester, [
      _node(
        'save',
        title: 'Emergency fund',
        favorite: true,
        money: const MoneyFacet(
          targetAmount: 100,
          actualAmount: 25,
          direction: MoneyDirection.save,
        ),
      ),
    ]);

    expect(find.byType(NodeCheckbox), findsNothing);
    expect(_barValue(tester), 0.25);
    expect(find.textContaining(r'$25.00 / $100.00'), findsOneWidget);
    expect(find.textContaining('25%'), findsOneWidget);
  });

  testWidgets('unbounded favorite stays an ongoing direction', (tester) async {
    await _pumpHome(tester, [
      _node('direction', title: 'Serve others', favorite: true, unbounded: true),
      _node('step', parents: const ['direction'], done: true),
    ]);

    expect(find.byType(NodeCheckbox), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.all_inclusive), findsOneWidget);
    expect(find.textContaining('unbounded · 1 step'), findsOneWidget);
  });
}
