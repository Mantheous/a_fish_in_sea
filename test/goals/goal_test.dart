import 'package:a_fish_in_sea/finances/model/budget.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/goals/bloc/goal_cubit.dart';
import 'package:a_fish_in_sea/goals/bloc/tag_cubit.dart';
import 'package:a_fish_in_sea/goals/model/goal.dart';
import 'package:a_fish_in_sea/goals/model/tag.dart';
import 'package:a_fish_in_sea/goals/service/goal_progress.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  Goal goal({
    required String id,
    GoalType type = GoalType.checklist,
    String? parentId,
    DateTime? start,
    DateTime? deadline,
    bool done = false,
    bool showInTasks = false,
  }) =>
      Goal(
        id: id,
        title: id,
        type: type,
        parentId: parentId,
        startDate: start ?? DateTime(2026, 1, 1),
        deadline: deadline ?? DateTime(2026, 12, 31),
        done: done,
        showInTasks: showInTasks,
      );

  group('nesting rules', () {
    test('checklist accepts any child; time/financial only their own', () {
      expect(canNest(GoalType.checklist, GoalType.time), isTrue);
      expect(canNest(GoalType.checklist, GoalType.financial), isTrue);
      expect(canNest(GoalType.time, GoalType.time), isTrue);
      expect(canNest(GoalType.time, GoalType.checklist), isFalse);
      expect(canNest(GoalType.financial, GoalType.time), isFalse);
    });

    test('GoalCubit rejects wrong-type child and out-of-span child', () {
      final cubit = GoalCubit();
      expect(
          cubit.addGoal(goal(
              id: 'time-parent',
              type: GoalType.time,
              deadline: DateTime(2026, 6, 30))),
          isNull);
      expect(
          cubit.addGoal(goal(
              id: 'bad-child',
              type: GoalType.checklist,
              parentId: 'time-parent')),
          isNotNull);
      expect(
          cubit.addGoal(goal(
              id: 'late-child',
              type: GoalType.time,
              parentId: 'time-parent',
              deadline: DateTime(2027, 1, 1))),
          isNotNull);
      expect(
          cubit.addGoal(goal(
              id: 'ok-child',
              type: GoalType.time,
              parentId: 'time-parent',
              start: DateTime(2026, 2, 1),
              deadline: DateTime(2026, 3, 1))),
          isNull);
    });

    test('deadline is required at the editor level: no default passthrough',
        () {
      final g = Goal.fromJson({
        'id': 'x',
        'title': 'x',
        'type': 'checklist',
        'startDate': DateTime(2026, 1, 1).toIso8601String(),
      });
      expect(g.deadline.millisecondsSinceEpoch, 0);
    });
  });

  group('progress', () {
    test('checklist parent averages children but stays uncompleted', () {
      final goals = [
        goal(id: 'p'),
        goal(id: 'a', parentId: 'p', done: true),
        goal(id: 'b', parentId: 'p'),
      ];
      final progress = progressForest(goals, const {});
      expect(progress['p'], 0.5);
      expect(goals.first.done, isFalse);
    });

    test('time leaf clamps actual/target', () {
      final g = Goal(
        id: 't',
        title: 'Study',
        type: GoalType.time,
        startDate: DateTime(2026, 1, 1),
        deadline: DateTime(2026, 12, 31),
        targetMinutes: 60,
      );
      expect(leafProgress(g, actual: 30), 0.5);
      expect(leafProgress(g, actual: 90), 1.0);
    });
  });

  group('tags', () {
    test('subtree includes descendants; cycles rejected', () {
      final cubit = TagCubit();
      cubit.addTag(const GoalTag(id: 'intellectual', name: 'Intellectual'));
      cubit.addTag(const GoalTag(
          id: 'school', name: 'School', parentId: 'intellectual'));
      expect(
          tagSubtreeIds('intellectual', cubit.state),
          containsAll(['intellectual', 'school']));
      expect(cubit.createsCycle('intellectual', 'school'), isTrue);
    });

    test('TagCubit restores tolerantly', () {
      final cubit = TagCubit();
      final restored = cubit.fromJson({
        'tags': [
          const GoalTag(id: 'a', name: 'A').toJson(),
          {'id': 42},
          'nope',
        ]
      });
      expect(restored?.map((t) => t.id), ['a']);
    });
  });

  group('persistence', () {
    test('goals round-trip and tolerate corrupt entries', () {
      final cubit = GoalCubit();
      final g = goal(id: 'g1', showInTasks: true, done: true);
      expect(Goal.fromJson(g.toJson()), g);
      final restored = cubit.fromJson({
        'goals': [g.toJson(), {'id': 42}, 'nope']
      });
      expect(restored?.map((x) => x.id), ['g1']);
    });

    test('unknown goal type falls back to checklist', () {
      final g = goal(id: 'g1');
      final json = g.toJson()..['type'] = 'renamed';
      expect(Goal.fromJson(json).type, GoalType.checklist);
    });

    test('budgets import as financial goals', () {
      final cubit = GoalCubit();
      cubit.importBudgets([
        Budget(
          id: 'b1',
          name: 'Food',
          category: 'food',
          goalAmount: 400,
          period: TimeScale.monthly,
          startDate: DateTime(2026, 1, 1),
        ),
      ]);
      expect(cubit.state.single.type, GoalType.financial);
      expect(cubit.state.single.targetAmount, 400);
    });
  });
}
