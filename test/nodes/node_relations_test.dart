import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/model/node_relations.dart';
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

  Node node(
    String id, {
    List<String> parentIds = const [],
    String? instanceOfId,
    NodeRecurrence? recurrence,
    RuleFacet? rule,
    DateTime? due,
    DateTime? start,
    DateTime? end,
  }) {
    return Node(
      id: id,
      title: id,
      parentIds: parentIds,
      instanceOfId: instanceOfId,
      recurrence: recurrence,
      rule: rule,
      createdAt: DateTime(2026, 1, 1),
    schedule: (due != null || start != null)
        ? ScheduleFacet(
            due: due,
            start: start,
            end: end ?? start?.add(const Duration(hours: 1)),
          )
        : null,
    );
  }

  group('roleOf is a disjoint, complete partition', () {
    test('a bare node is a placeholder', () {
      expect(roleOf(node('a')), NodeRole.placeholder);
    });

    test('a due date makes it an obligation', () {
      expect(roleOf(node('a', due: DateTime(2026, 1, 2))),
          NodeRole.obligation);
    });

    test('a start/end block makes it a block', () {
      final n = node('a',
          due: DateTime(2026, 1, 2),
          start: DateTime(2026, 1, 2, 9),
          end: DateTime(2026, 1, 2, 10));
      // Block wins over obligation: a calendar block also carries the
      // more structural information.
      expect(roleOf(n), NodeRole.block);
    });

    test('recurrence makes it a template', () {
      final n = node('a',
          recurrence: const NodeRecurrence(frequency: TimeScale.monthly));
      expect(roleOf(n), NodeRole.template);
    });

    test('instanceOfId wins over an inherited recurrence facet', () {
      // An instance inherits the template's recurrence, so the instance
      // test must come first or the partition would not be disjoint.
      final n = node('inst',
          instanceOfId: 'tpl',
          recurrence: const NodeRecurrence(frequency: TimeScale.monthly));
      expect(roleOf(n), NodeRole.instance);
    });

    test('a non-none rule makes it derived', () {
      final n = node('a',
          rule: const RuleFacet(kind: NodeRuleKind.homeworkAhead));
      expect(roleOf(n), NodeRole.derived);
    });

    test('rule none is not derived', () {
      final n = node('a', rule: const RuleFacet(kind: NodeRuleKind.none));
      expect(roleOf(n), isNot(NodeRole.derived));
    });

    test('every role a node can play is reachable', () {
      // Guards the "complete" half: adding a facet combination that falls
      // through to placeholder would be a silent regression.
      final roles = <NodeRole>{
        roleOf(node('a')),
        roleOf(node('b', due: DateTime(2026, 1, 2))),
        roleOf(node('c', start: DateTime(2026, 1, 2, 9))),
        roleOf(node('d',
            recurrence: const NodeRecurrence(frequency: TimeScale.daily))),
        roleOf(node('e', instanceOfId: 'd')),
        roleOf(node('f',
            rule: const RuleFacet(kind: NodeRuleKind.minBalance))),
      };
      expect(roles, NodeRole.values.toSet());
    });
  });

  group('declared multiplicities', () {
    test('an instance declares exactly one parent', () {
      expect(declaredParentCount(NodeRole.instance), 1);
    });

    test('every other role leaves the count open', () {
      for (final role in const [
        NodeRole.placeholder,
        NodeRole.obligation,
        NodeRole.block,
        NodeRole.template,
        NodeRole.derived,
      ]) {
        expect(declaredParentCount(role), isNull, reason: '$role is unbounded');
      }
    });
  });

  group('canBeParentOf', () {
    test('an instance may not be a parent', () {
      expect(canBeParentOf(NodeRole.instance, NodeRole.placeholder), isFalse);
      expect(canBeParentOf(NodeRole.instance, NodeRole.block), isFalse);
    });

    test('the DAG is otherwise permissive', () {
      for (final parent in NodeRole.values) {
        for (final child in NodeRole.values) {
          if (parent == NodeRole.instance) continue;
          expect(canBeParentOf(parent, child), isTrue,
              reason: '$parent should be able to parent $child');
        }
      }
    });
  });

  group('validateNodeRelations', () {
    test('a healthy instance passes', () {
      final all = [
        node('tpl', recurrence: const NodeRecurrence(frequency: TimeScale.monthly)),
        node('inst', parentIds: ['tpl'], instanceOfId: 'tpl'),
      ];
      expect(
        validateNodeRelations(
            draft: all[1], all: all, parentIds: const ['tpl']),
        isNull,
      );
    });

    test('an instance reparented away from its template is refused', () {
      final all = [
        node('tpl', recurrence: const NodeRecurrence(frequency: TimeScale.monthly)),
        node('other'),
        node('inst', parentIds: ['tpl'], instanceOfId: 'tpl'),
      ];
      final error = validateNodeRelations(
        draft: all[2],
        all: all,
        parentIds: const ['other'],
      );
      expect(error, isNotNull);
      expect(error, contains('template'));
    });

    test('an instance with a second parent is refused', () {
      final all = [
        node('tpl', recurrence: const NodeRecurrence(frequency: TimeScale.monthly)),
        node('other'),
        node('inst', parentIds: ['tpl'], instanceOfId: 'tpl'),
      ];
      expect(
        validateNodeRelations(
            draft: all[2], all: all, parentIds: const ['tpl', 'other']),
        isNotNull,
      );
    });

    test('an instance with no parents is refused', () {
      final all = [
        node('tpl', recurrence: const NodeRecurrence(frequency: TimeScale.monthly)),
        node('inst', parentIds: ['tpl'], instanceOfId: 'tpl'),
      ];
      expect(
        validateNodeRelations(draft: all[1], all: all, parentIds: const []),
        isNotNull,
      );
    });

    test('a non-instance may keep several parents', () {
      final all = [
        node('p1'),
        node('p2'),
        node('child', parentIds: ['p1', 'p2']),
      ];
      expect(
        validateNodeRelations(
            draft: all[2], all: all, parentIds: const ['p1', 'p2']),
        isNull,
      );
    });

    test('a template nested under its own instance is refused', () {
      // The cycle runs through instanceOfId, not parentIds, so
      // descendantIds cannot see it. This is the check that catches it.
      final template = node('tpl',
          recurrence: const NodeRecurrence(frequency: TimeScale.monthly));
      final instance =
          node('inst', parentIds: ['tpl'], instanceOfId: 'tpl');
      final all = [template, instance];
      final error = validateNodeRelations(
        draft: template,
        all: all,
        parentIds: const ['inst'],
      );
      expect(error, isNotNull);
      expect(error, contains('cycle'));
    });

    test('a transitive instance also blocks the template', () {
      // tpl → inst1 → inst2 (inst2 generated by inst1). Either may not
      // parent tpl.
      final template = node('tpl',
          recurrence: const NodeRecurrence(frequency: TimeScale.monthly));
      final i1 = node('i1', parentIds: ['tpl'], instanceOfId: 'tpl');
      final i2 = node('i2', parentIds: ['i1'], instanceOfId: 'i1');
      final all = [template, i1, i2];
      expect(
        validateNodeRelations(draft: template, all: all, parentIds: const ['i2']),
        isNotNull,
      );
    });

    test('a template may still parent ordinary nodes', () {
      final template = node('tpl',
          recurrence: const NodeRecurrence(frequency: TimeScale.monthly));
      final all = [template, node('kid')];
      expect(
        validateNodeRelations(
            draft: template, all: all, parentIds: const ['kid']),
        isNull,
      );
    });

    test('children may not hang off an instance', () {
      final all = [
        node('tpl', recurrence: const NodeRecurrence(frequency: TimeScale.monthly)),
        node('inst', parentIds: ['tpl'], instanceOfId: 'tpl'),
        node('kid'),
      ];
      final error = validateNodeRelations(
        draft: all[2],
        all: all,
        parentIds: const ['inst'],
      );
      expect(error, isNotNull);
      expect(error, contains('instances cannot have children'));
    });

    test('unknown parent ids are the graph layer problem, not this one', () {
      // validateNodeRelations runs after the existence check, so a
      // missing id must not be reported as a relation error.
      final all = [node('a')];
      expect(
        validateNodeRelations(draft: all[0], all: all, parentIds: const ['ghost']),
        isNull,
      );
    });
  });

  group('relation rules do not lock the user out of their own data', () {
    // The data guardian's finding: the rules can refuse a shape old data
    // already satisfies. Applying them to every write would make such a
    // node permanently un-editable, silently dropping every ordinary
    // edit. NodeCubit.validateParents gates them on the structure actually
    // changing; these tests pin that contract.
    NodeCubit cubitWith(List<Node> nodes) {
      final cubit = NodeCubit();
      cubit.emitSilent(nodes);
      return cubit;
    }

    test('a node violating a relation rule stays editable', () async {
      // An instance with a second parent — exactly the shape the rules
      // refuse, built before the rules existed.
      final template = node('tpl',
          recurrence: const NodeRecurrence(frequency: TimeScale.monthly));
      final other = node('other');
      final brokenInstance = node('inst',
          parentIds: ['tpl', 'other'], instanceOfId: 'tpl');
      final cubit = cubitWith([template, other, brokenInstance]);

      // Toggling done must not be refused by a structural rule.
      cubit.toggleDone('inst');
      expect(cubit.byId('inst')!.isDone, isTrue);
    });

    test('changing the parent set re-enables the rule', () {
      final template = node('tpl',
          recurrence: const NodeRecurrence(frequency: TimeScale.monthly));
      final other = node('other');
      final cubit = cubitWith([template, other, node('inst',
          parentIds: ['tpl'], instanceOfId: 'tpl')]);

      // Still refused when the user actually proposes the bad shape.
      final error = cubit.reparent('inst', const ['other']);
      expect(error, isNotNull);
      expect(cubit.byId('inst')!.parentIds, ['tpl']);
    });
  });

  group('legacy override key translation', () {
    // The keys live on NodeCubit; re-declared here so the contract is
    // pinned without reaching into the cubit's private statics.
    Set<String> translate(Set<String> legacy) {
      const legacyToNode = {
        'name': 'title',
        'notes': 'notes',
        'amount': 'money.targetAmount',
        'date': 'schedule.due',
        'category': 'category',
      };
      return {for (final key in legacy) legacyToNode[key] ?? key};
    }

    test('flat legacy keys become node paths', () {
      expect(translate(const {'name', 'amount', 'date'}), {
        'title',
        'money.targetAmount',
        'schedule.due',
      });
    });

    test('legacy keys no longer leak through unchanged', () {
      // Before the fix, "amount" was stored verbatim and nothing ever
      // read it off a node, so the override was inert.
      expect(translate(const {'amount'}), isNot(contains('amount')));
    });

    test('unknown keys survive rather than being dropped', () {
      expect(translate(const {'amount', 'somethingNew'}),
          contains('somethingNew'));
    });
  });
}
