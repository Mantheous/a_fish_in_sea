import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/assignment_estimates_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/assignment_rules_cubit.dart';
import 'package:a_fish_in_sea/planner/view/assignment_rules_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

/// A homework node with three recorded sessions of 30/45/60 minutes on
/// `math290|video quiz`, which is what the sheet's learned figures read.
List<Node> _recordedNodes() {
  Node at(String id, int day, int minutes) {
    final start = DateTime(2026, 10, day, 19);
    return Node(
      id: id,
      title: 'Video Quiz 3.${day - 4}',
      createdAt: DateTime(2026, 9, 1),
      feedId: 'math290',
      classId: 'math290',
      classLabel: 'MATH 290',
      sourceEventId: 'evt:$id',
      schedule: ScheduleFacet(due: start.add(const Duration(days: 1))),
      actualStart: start,
      actualEnd: start.add(Duration(minutes: minutes)),
    );
  }

  return [at('a', 5, 30), at('b', 6, 45), at('c', 7, 60)];
}

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  Future<void> pumpSheet(
    WidgetTester tester, {
    required AssignmentRulesCubit rules,
    required AssignmentEstimatesCubit estimates,
    required NodeCubit nodes,
  }) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider(create: (_) => UndoCubit()),
          BlocProvider.value(value: rules),
          BlocProvider.value(value: estimates),
          BlocProvider.value(value: nodes),
        ],
        child: const MaterialApp(
          home: Scaffold(body: _RulesEntry()),
        ),
      ),
    );
    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();
  }

  testWidgets('shows the learned duration and habitual start', (tester) async {
    final nodes = NodeCubit()..emitMany(_recordedNodes());
    final estimates = AssignmentEstimatesCubit()
      ..rebuildFrom(nodes.state);
    final rules = AssignmentRulesCubit()
      ..createRule(
        feedId: 'math290',
        templateKey: 'video quiz',
        displayName: 'Video Quiz',
        dueOffsetDays: -2,
      );

    await pumpSheet(
      tester,
      rules: rules,
      estimates: estimates,
      nodes: nodes,
    );

    // Median of 30/45/60 = 45 minutes, and all three started at 7 PM.
    expect(find.text('Expected time'), findsOneWidget);
    expect(find.text('45 min each · around 7 PM'), findsOneWidget);
  });

  testWidgets('stepping the expected time writes it to the rule', (tester) async {
    final nodes = NodeCubit()..emitMany(_recordedNodes());
    final estimates = AssignmentEstimatesCubit()
      ..rebuildFrom(nodes.state);
    final rules = AssignmentRulesCubit()
      ..createRule(
        feedId: 'math290',
        templateKey: 'video quiz',
        displayName: 'Video Quiz',
        dueOffsetDays: -2,
      );

    await pumpSheet(
      tester,
      rules: rules,
      estimates: estimates,
      nodes: nodes,
    );

    expect(rules.state.single.estimateMinutes, isNull);
    await tester.tap(find.byTooltip('More time'));
    await tester.pumpAndSettle();
    expect(rules.state.single.estimateMinutes, 50);
    // With an override on, the learned value stays available.
    expect(find.text('Use learned'), findsOneWidget);

    // Going back to the learned number clears the override.
    await tester.tap(find.text('Use learned'));
    await tester.pumpAndSettle();
    expect(rules.state.single.estimateMinutes, isNull);
    expect(find.text('45 min each · around 7 PM'), findsOneWidget);
  });
}

/// Opens the rules sheet the same way the Tasks page does.
class _RulesEntry extends StatelessWidget {
  const _RulesEntry();

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => showAssignmentRules(context),
      child: const Text('open'),
    );
  }
}

extension on NodeCubit {
  void emitMany(List<Node> nodes) => emitSilent(nodes);
}
