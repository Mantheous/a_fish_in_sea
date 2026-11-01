import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/goal_graph_filter.dart';
import 'package:a_fish_in_sea/nodes/service/node_budget_progress.dart';
import 'package:a_fish_in_sea/nodes/service/node_progress.dart';
import 'package:a_fish_in_sea/nodes/service/node_tree_ops.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

Node node(
  String id, {
  List<String> parents = const [],
  NodeStatus status = NodeStatus.open,
  ScheduleFacet? schedule,
  MoneyFacet? money,
  EffortFacet? effort,
  String? sourceEventId,
  String? calendarEventId,
  String? instanceOfId,
  bool? taskFlag,
}) =>
    Node(
      id: id,
      title: id,
      parentIds: parents,
      status: status,
      createdAt: DateTime(2026, 9, 1),
      schedule: schedule,
      money: money,
      effort: effort,
      sourceEventId: sourceEventId,
      calendarEventId: calendarEventId,
      instanceOfId: instanceOfId,
      taskFlag: taskFlag,
    );

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  group('planBreakdown', () {
    test('money splits to the cent and sums exactly', () {
      final parent = node('goal',
          schedule: ScheduleFacet(
            start: DateTime(2026, 9, 1),
            due: DateTime(2026, 9, 30),
          ),
          money: const MoneyFacet(targetAmount: 100));
      final slices = planBreakdown(
        parent: parent,
        count: 3,
        now: DateTime(2026, 9, 1),
      );
      expect(slices.length, 3);
      final total =
          slices.fold<double>(0, (sum, s) => sum + (s.targetAmount ?? 0));
      expect(total, closeTo(100, 0.001));
      // Dues spread evenly and ordered.
      final dues = [for (final s in slices) s.due!];
      expect(dues, orderedEquals([...dues]..sort()));
      expect(dues.last, DateTime(2026, 9, 30));
    });

    test('effort splits whole minutes and sums exactly', () {
      final parent = node('goal',
          effort: const EffortFacet(targetMinutes: 100));
      final slices = planBreakdown(
        parent: parent,
        count: 3,
        now: DateTime(2026, 9, 1),
      );
      final total =
          slices.fold<int>(0, (sum, s) => sum + (s.targetMinutes ?? 0));
      expect(total, 100);
      expect(
        slices.map((s) => s.targetMinutes),
        [34, 33, 33],
      );
    });

    test('undated parent defaults to a day-per-step window from now', () {
      final parent = node('idea');
      final now = DateTime(2026, 9, 1, 9);
      final slices = planBreakdown(
        parent: parent,
        count: 4,
        now: now,
      );
      expect(slices.length, 4);
      expect(slices.first.due, now.add(const Duration(days: 1)));
      expect(slices.last.due, now.add(const Duration(days: 4)));
      expect(slices.first.targetAmount, isNull);
      expect(slices.first.targetMinutes, isNull);
    });

    test('count clamps to 2..30', () {
      final parent = node('goal');
      expect(
        planBreakdown(
          parent: parent,
          count: 1,
          now: DateTime(2026, 9, 1),
        ).length,
        2,
      );
      expect(
        planBreakdown(
          parent: parent,
          count: 99,
          now: DateTime(2026, 9, 1),
        ).length,
        30,
      );
    });
  });

  group('subtree + search helpers', () {
    test('subtreeIds covers the closure, cycle-safe', () {
      final all = [
        node('a'),
        node('b', parents: ['a']),
        node('c', parents: ['a', 'b']),
        node('outside'),
      ];
      expect(subtreeIds('a', all), {'b', 'c'});
      expect(subtreeIds('outside', all), isEmpty);
    });

    test('filterTreeIds keeps matches, ancestors, and subtrees', () {
      final all = [
        node('root'),
        node('math', parents: ['root']),
        node('algebra', parents: ['math']),
        node('groceries', parents: ['root']),
      ];
      // Match title directly.
      final hit = filterTreeIds(all, 'algebra');
      expect(hit, containsAll(['algebra', 'math', 'root']));
      expect(hit, isNot(contains('groceries')));
      // Empty query keeps everything.
      expect(filterTreeIds(all, '  '), hasLength(4));
      // No match keeps nothing.
      expect(filterTreeIds(all, 'zzz'), isEmpty);
    });
  });

  group('createChild', () {
    test('adds a child in one step; errors on bad input', () {
      final cubit = NodeCubit();
      expect(cubit.addNode(node('goal')), isNull);
      expect(
        cubit.createChild('goal',
            nodeId: 'step1', title: 'First step'),
        isNull,
      );
      expect(cubit.byId('step1')?.parentIds, ['goal']);
      expect(
          cubit.createChild('missing', nodeId: 'x'), isNotNull);
      expect(
          cubit.createChild('goal', nodeId: 'y', title: '  '),
          isNotNull);
      expect(
          cubit.createChild('goal', nodeId: 'step1'), isNotNull);
    });
  });

  group('addNodeWithChildren', () {
    test('adds a parent and attaches children in one change', () {
      final cubit = NodeCubit();
      expect(cubit.addNode(node('goal')), isNull);
      expect(cubit.addNode(node('other')), isNull);
      expect(cubit.addNode(node('child', parents: ['goal', 'other'])), isNull);

      expect(
        cubit.addNodeWithChildren(node('parent'), childIds: ['child']),
        isNull,
      );
      final parent = cubit.byId('parent');
      expect(parent, isNotNull);
      expect(parent!.parentIds, isEmpty, reason: 'new goal starts as a root');
      // The DAG keeps existing parents: adding a parent never steals the
      // child from the rest of the tree.
      expect(cubit.byId('child')?.parentIds, ['goal', 'other', 'parent']);
    });

    test('rejects generated instances without writing anything', () {
      final cubit = NodeCubit();
      expect(cubit.addNode(node('template')), isNull);
      expect(
        cubit.addNode(
          node('inst', parents: ['template'], instanceOfId: 'template'),
        ),
        isNull,
      );
      // A generated instance must stay parented to its template only.
      final before = cubit.state;
      expect(
        cubit.addNodeWithChildren(node('parent'), childIds: ['inst']),
        isNotNull,
      );
      expect(identical(cubit.state, before), isTrue);
      expect(cubit.byId('parent'), isNull);
    });

    test('rejects unknown children and duplicate ids', () {
      final cubit = NodeCubit();
      expect(cubit.addNode(node('goal')), isNull);
      expect(
        cubit.addNodeWithChildren(node('parent'), childIds: ['missing']),
        isNotNull,
      );
      expect(cubit.byId('parent'), isNull);
      expect(
        cubit.addNodeWithChildren(node('goal')),
        isNotNull,
        reason: 'duplicate id',
      );
    });
  });

  group('duplicateSubtree', () {
    for (final flag in <bool?>[true, false, null]) {
      test('preserves nullable task setting $flag on root and child', () {
        final cubit = NodeCubit();
        addTearDown(cubit.close);
        cubit.addNode(node('goal', taskFlag: flag));
        cubit.addNode(node('child', parents: ['goal'], taskFlag: flag));

        expect(cubit.duplicateSubtree('goal', idSuffix: 't'), isNull);
        const filter = GoalGraphFilter(kind: GoalKindFilter.task);
        for (final id in ['goal', 'child']) {
          final original = cubit.byId(id)!;
          final copy = cubit.byId('${id}_copy_t')!;
          expect(copy.schedule, isNull);
          expect(copy.taskFlag, flag);
          expect(copy.isTask, flag ?? false);
          expect(filter.matches(copy, DateTime(2026, 9, 1)), flag ?? false);
          expect(original.taskFlag, flag);
        }
      });
    }

    test('preserves explicit task off and inferred task on dated copies', () {
      final cubit = NodeCubit();
      addTearDown(cubit.close);
      for (final flag in <bool?>[false, null]) {
        final id = 'dated_$flag';
        cubit.addNode(node(id, taskFlag: flag,
            schedule: ScheduleFacet(due: DateTime(2026, 9, 15))));
        expect(cubit.duplicateSubtree(id, idSuffix: 't'), isNull);
        final copy = cubit.byId('${id}_copy_t')!;
        expect(copy.taskFlag, flag);
        expect(copy.isTask, flag ?? true);
      }
    });

    test('deep-copies the closure, keeps shared parents, strips links',
        () {
      final cubit = NodeCubit();
      cubit.addNode(node('goal'));
      cubit.addNode(node('other'));
      cubit.addNode(node('child',
          parents: ['goal', 'other'],
          schedule: ScheduleFacet(due: DateTime(2026, 9, 15)),
          money: const MoneyFacet(
              targetAmount: 50, actualAmount: 50,
              linkedTransactionIds: ['purchase'])));
      cubit.addNode(node('grand', parents: ['child']));
      cubit.addNode(node('linked',
          parents: ['goal'],
          sourceEventId: 'evt-1',
          calendarEventId: 'cal-1',
          status: NodeStatus.done));

      expect(
        cubit.duplicateSubtree('goal', idSuffix: 't'),
        isNull,
      );
      final copy = cubit.byId('goal_copy_t')!;
      expect(copy.title, 'goal (copy)');
      expect(copy.isOpen, isTrue);
      final childCopy = cubit.byId('child_copy_t')!;
      // Internal parent remapped, external parent preserved.
      expect(
        childCopy.parentIds,
        containsAll(['goal_copy_t', 'other']),
      );
      expect(childCopy.money?.status, MoneyStatus.projected);
      expect(childCopy.money?.actualAmount, isNull);
      expect(childCopy.money?.linkedTransactionIds, isEmpty);
      expect(cubit.byId('grand_copy_t')?.parentIds, ['child_copy_t']);
      // Event links are stripped on copies; completion reset.
      final linkedCopy = cubit.byId('linked_copy_t')!;
      expect(linkedCopy.sourceEventId, isNull);
      expect(linkedCopy.calendarEventId, isNull);
      expect(linkedCopy.isOpen, isTrue);
      // Originals untouched.
      expect(cubit.byId('child')?.parentIds, ['goal', 'other']);
      expect(cubit.byId('child')?.money?.linkedTransactionIds, ['purchase']);
    });

    test('copied purchase history never doubles the shared budget spending', () {
      final cubit = NodeCubit();
      final undo = UndoCubit();
      addTearDown(cubit.close);
      addTearDown(undo.close);
      final budget = node('budget', money: const MoneyFacet(
        targetAmount: 500, period: TimeScale.monthly));
      cubit.addNode(budget);
      cubit.addNode(node('child', parents: ['budget'],
          money: const MoneyFacet(targetAmount: 50)));
      final purchase = Transaction(
        id: 'purchase', accountId: 'checking', amount: -50,
        date: DateTime(2026, 9, 12), name: 'Groceries',
        assignedNodeId: 'child',
      );
      cubit.linkTransaction(nodeId: 'child', transactionId: purchase.id,
          transactionAmount: purchase.amount);
      final original = cubit.byId('child')!;
      double spending() => moneyActualForActivePeriod(
          budget, cubit.state, [purchase], now: DateTime(2026, 9, 15));
      expect(spending(), 50);
      undo.resetHistory();

      expect(cubit.duplicateSubtree('child', idSuffix: 't'), isNull);
      final copy = cubit.byId('child_copy_t')!;
      expect(copy.parentIds, ['budget']);
      expect(copy.money?.targetAmount, 50);
      expect(copy.money?.status, MoneyStatus.projected);
      expect(copy.money?.actualAmount, isNull);
      expect(copy.money?.linkedTransactionIds, isEmpty);
      expect(cubit.byId('child'), original);
      expect(purchase.assignedNodeId, original.id);
      expect(spending(), 50);
      expect(undo.state.undoStack, hasLength(1));

      undo.undo();
      expect(cubit.byId(copy.id), isNull);
      expect(cubit.byId('child'), original);
      expect(spending(), 50);
      undo.redo();
      expect(cubit.byId(copy.id)?.money?.linkedTransactionIds, isEmpty);
      expect(cubit.byId('child'), original);
      expect(spending(), 50);
    });

    test('rejects missing nodes and self-subtree attachment', () {
      final cubit = NodeCubit();
      cubit.addNode(node('a'));
      cubit.addNode(node('b', parents: ['a']));
      expect(
          cubit.duplicateSubtree('nope', idSuffix: 't'), isNotNull);
      expect(
        cubit.duplicateSubtree('a',
            attachToParentId: 'b', idSuffix: 't'),
        isNotNull,
      );
      expect(
        cubit.duplicateSubtree('a',
            attachToParentId: 'missing', idSuffix: 't'),
        isNotNull,
      );
    });
  });

  group('breakdownGoal', () {
    test('creates dated, funded steps that sum to the parent', () {
      final cubit = NodeCubit();
      cubit.addNode(node('semester',
          schedule: ScheduleFacet(
            start: DateTime(2026, 9, 1),
            due: DateTime(2026, 9, 29),
          ),
          money: const MoneyFacet(targetAmount: 400),
          effort: const EffortFacet(targetMinutes: 120)));
      final result = cubit.breakdownGoal(
        'semester',
        count: 4,
        now: DateTime(2026, 9, 1),
      );
      expect(result.error, isNull);
      expect(result.ids, hasLength(4));
      final kids = cubit.childrenOf('semester');
      expect(kids, hasLength(4));
      final dues = [for (final k in kids) k.schedule?.due];
      expect(dues.toSet(), hasLength(4));
      expect(
        dues,
        orderedEquals([...dues]..sort()),
      );
      final moneyTotal = kids.fold<double>(
          0, (sum, k) => sum + (k.money?.targetAmount ?? 0));
      expect(moneyTotal, closeTo(400, 0.001));
      final effortTotal = kids.fold<int>(
          0, (sum, k) => sum + (k.effort?.targetMinutes ?? 0));
      expect(effortTotal, 120);
      // Steps are estimates: flexible, unfinished.
      expect(kids.every((k) => k.isOpen), isTrue);
      expect(
        kids.every((k) => k.money?.isFixed == false),
        isTrue,
      );
    });

    test('errors on missing parent; clamps wild counts', () {
      final cubit = NodeCubit();
      final missing = cubit.breakdownGoal('nope', count: 4);
      expect(missing.error, isNotNull);
      expect(missing.ids, isEmpty);
      cubit.addNode(node('g'));
      final tiny = cubit.breakdownGoal(
        'g',
        count: 1,
        now: DateTime(2026, 9, 1),
      );
      expect(tiny.error, isNull);
      expect(tiny.ids, hasLength(2));
    });

    test('broken-down children roll up through progress', () {
      final cubit = NodeCubit();
      cubit.addNode(node('goal',
          money: const MoneyFacet(targetAmount: 100)));
      final result = cubit.breakdownGoal(
        'goal',
        count: 2,
        now: DateTime(2026, 9, 1),
      );
      expect(result.error, isNull);
      // Reporting one 50 step fills half the parent cap.
      cubit.linkTransaction(
        nodeId: result.ids.first,
        transactionId: 'plaid-1',
        transactionAmount: -50,
      );
      final progress = progressForest(cubit.state);
      expect(progress['goal'], closeTo(0.5, 0.001));
    });
  });
}
