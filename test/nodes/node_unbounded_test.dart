import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/model/node_relations.dart';
import 'package:a_fish_in_sea/nodes/service/node_progress.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

Node node(
  String id, {
  List<String> parents = const [],
  NodeStatus status = NodeStatus.open,
  bool isUnbounded = false,
  ScheduleFacet? schedule,
  MoneyFacet? money,
  EffortFacet? effort,
  NodeRecurrence? recurrence,
  RuleFacet? rule,
  String? instanceOfId,
}) =>
    Node(
      id: id,
      title: id,
      parentIds: parents,
      status: status,
      createdAt: DateTime(2026, 9, 1),
      isUnbounded: isUnbounded,
      schedule: schedule,
      money: money,
      effort: effort,
      recurrence: recurrence,
      rule: rule,
      instanceOfId: instanceOfId,
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

  group('unbounded flag persistence', () {
    test('round-trips true', () {
      final n = node('abstract', isUnbounded: true);
      expect(Node.fromJson(n.toJson()), n);
      expect(Node.fromJson(n.toJson()).isUnbounded, isTrue);
    });

    test('missing or wrong-typed flag loads as bounded', () {
      final legacy = node('old').toJson()..remove('isUnbounded');
      expect(Node.fromJson(legacy).isUnbounded, isFalse);
      final corrupt = node('bad').toJson()..['isUnbounded'] = 'yes';
      expect(Node.fromJson(corrupt).isUnbounded, isFalse);
      final cubit = NodeCubit();
      final restored = cubit.fromJson({
        'nodes': [legacy, corrupt, node('ok').toJson()],
      });
      expect(restored?.map((n) => n.id), ['old', 'bad', 'ok']);
    });
  });

  group('unbounded validation', () {
    test('bare unbounded node is accepted', () {
      final cubit = NodeCubit();
      expect(cubit.addNode(node('serve-others', isUnbounded: true)), isNull);
      expect(cubit.byId('serve-others')?.isUnbounded, isTrue);
    });

    test('unbounded with any facet or instance link is rejected', () {
      final day = DateTime(2026, 9, 12);
      final cases = [
        node('a',
            isUnbounded: true, schedule: ScheduleFacet(due: day)),
        node('b',
            isUnbounded: true,
            money: const MoneyFacet(targetAmount: 10)),
        node('c',
            isUnbounded: true,
            effort: const EffortFacet(targetMinutes: 10)),
        node('d',
            isUnbounded: true,
            recurrence:
                const NodeRecurrence(frequency: TimeScale.daily)),
        node('e',
            isUnbounded: true,
            rule: const RuleFacet(
                kind: NodeRuleKind.homeworkAhead)),
        node('f', isUnbounded: true, instanceOfId: 'tmpl'),
      ];
      for (final draft in cases) {
        expect(validateUnbounded(draft), isNotNull,
            reason: '${draft.id} should be rejected');
        final cubit = NodeCubit();
        expect(cubit.addNode(draft), isNotNull,
            reason: '${draft.id} should not be stored');
        expect(cubit.byId(draft.id), isNull);
      }
    });

    test('adding a schedule to an unbounded node is rejected', () {
      final cubit = NodeCubit();
      expect(cubit.addNode(node('abs', isUnbounded: true)), isNull);
      final withDue = cubit.byId('abs')!.copyWith(
        schedule: ScheduleFacet(due: DateTime(2026, 9, 20)),
      );
      expect(cubit.updateNode(withDue), isNotNull);
      expect(cubit.byId('abs')?.schedule, isNull);
    });

    test('editor-style save clears facets when going unbounded', () {
      final cubit = NodeCubit();
      expect(
          cubit.addNode(node('g',
              schedule: ScheduleFacet(due: DateTime(2026, 9, 20)))),
          isNull);
      final asAbstract = cubit.byId('g')!.copyWith(
        isUnbounded: true,
        clearSchedule: true,
      );
      expect(cubit.updateNode(asAbstract), isNull);
      expect(cubit.byId('g')?.isUnbounded, isTrue);
      expect(cubit.byId('g')?.schedule, isNull);
    });

    test('unbounded goals read as placeholders', () {
      expect(
          roleOf(node('abs', isUnbounded: true)), NodeRole.placeholder);
    });
  });

  group('example: serve others', () {
    List<Node> serveOthersSet() {
      final cubit = NodeCubit();
      cubit.addNode(node('serve-others', isUnbounded: true));
      cubit.addNode(node('serve-this-week',
          parents: ['serve-others'],
          schedule: ScheduleFacet(due: DateTime(2026, 9, 14))));
      return cubit.state;
    }

    test('concrete subgoal queues; abstract parent does not', () {
      final all = serveOthersSet();
      final now = DateTime(2026, 9, 12);
      expect(priorityQueue(all, now).map((n) => n.id),
          ['serve-this-week']);
      expect(leafNodes(all).map((n) => n.id), ['serve-this-week']);
      // The abstract goal still exists in the tree view.
      expect(goalNodes(all).map((n) => n.id),
          contains('serve-others'));
    });

    test('abstract goal stays out of the to-do list and week views', () {
      final cubit = NodeCubit();
      cubit.addNode(node('serve-others', isUnbounded: true));
      cubit.addNode(node('serve-this-week',
          parents: ['serve-others'],
          schedule: ScheduleFacet(due: DateTime(2026, 9, 14))));
      expect(cubit.openNodes.map((n) => n.id), ['serve-this-week']);
      expect(
          cubit.overdueAndTodayAt(DateTime(2026, 9, 14)).map((n) => n.id),
          ['serve-this-week']);
      expect(cubit.dueThisWeekAt(DateTime(2026, 9, 12)).map((n) => n.id),
          ['serve-this-week']);
    });

    test('done concrete subgoal does not "complete" the abstract parent', () {
      final cubit = NodeCubit();
      cubit.addNode(node('serve-others', isUnbounded: true));
      cubit.addNode(node('serve-this-week',
          parents: ['serve-others'],
          schedule: ScheduleFacet(due: DateTime(2026, 9, 14))));
      cubit.toggleDone('serve-this-week');
      // The parent is unbounded: the UI shows no bar and no checkbox, so
      // it can never read as finished.
      expect(cubit.byId('serve-others')?.isDone, isFalse);
    });

    test('unbounded child never pins a concrete parent below 100%', () {
      final cubit = NodeCubit();
      cubit.addNode(node('week'));
      cubit.addNode(node('serve-others',
          parents: ['week'], isUnbounded: true));
      cubit.addNode(
          node('concrete-step', parents: ['week'], status: NodeStatus.done));
      final progress = progressForest(cubit.state);
      expect(progress['week'], 1.0);
    });
  });

  group('unbounded duplication', () {
    test('duplicateSubtree carries the flag', () {
      final cubit = NodeCubit();
      cubit.addNode(node('serve-others', isUnbounded: true));
      cubit.addNode(node('serve-this-week',
          parents: ['serve-others'],
          schedule: ScheduleFacet(due: DateTime(2026, 9, 14))));
      expect(cubit.duplicateSubtree('serve-others'), isNull);
      final copy =
          cubit.state.firstWhere((n) => n.title == 'serve-others (copy)');
      expect(copy.isUnbounded, isTrue);
      expect(copy.schedule, isNull);
    });
  });
}
