import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_bulk_edit.dart';
import 'package:flutter_test/flutter_test.dart';

Node _node(
  String id, {
  String title = '',
  String? notes,
  List<String> parents = const [],
  ScheduleFacet? schedule,
  MoneyFacet? money,
  EffortFacet? effort,
  AnkiFacet? anki,
  NodeRecurrence? recurrence,
  AutoFacet? auto,
  RuleFacet? rule,
  bool isUnbounded = false,
  bool isFavorite = false,
  bool? taskFlag,
  String? classNodeId,
  String? classId,
  String? classLabel,
  String? feedId,
  ClassFacet? classFacet,
}) => Node(
  id: id,
  title: title.isEmpty ? id : title,
  notes: notes,
  parentIds: parents,
  createdAt: DateTime(2026),
  schedule: schedule,
  money: money,
  effort: effort,
  anki: anki,
  recurrence: recurrence,
  auto: auto,
  rule: rule,
  isUnbounded: isUnbounded,
  isFavorite: isFavorite,
  taskFlag: taskFlag,
  classNodeId: classNodeId,
  classId: classId,
  classLabel: classLabel,
  feedId: feedId,
  classFacet: classFacet,
);

void main() {
  group('applyBulkEdits', () {
    test('notes and flags change every goal, titles stay untouched', () {
      final a = _node('a', title: 'Alpha');
      final b = _node('b', title: 'Beta', isFavorite: true);
      final changed = applyBulkEdits(
        [a, b],
        const NodeBulkEdits(
          applyNotes: true,
          notes: '  Shared context  ',
          favorite: false,
          task: true,
        ),
        byId: {'a': a, 'b': b},
      );

      expect(changed, hasLength(2));
      for (final node in changed) {
        expect(node.title, node.id == 'a' ? 'Alpha' : 'Beta');
        expect(node.notes, 'Shared context');
        expect(node.isFavorite, isFalse);
        expect(node.taskFlag, isTrue);
      }
    });

    test('blank notes clear instead of writing an empty string', () {
      final a = _node('a', notes: 'old');
      final changed = applyBulkEdits(
        [a],
        const NodeBulkEdits(applyNotes: true, notes: '   '),
        byId: {'a': a},
      );
      expect(changed.single.notes, isNull);
    });

    test('parents are added and removed without replacing the rest', () {
      final a = _node('a', parents: const ['p1', 'p2']);
      final p1 = _node('p1');
      final p2 = _node('p2');
      final p3 = _node('p3');
      final changed = applyBulkEdits(
        [a],
        const NodeBulkEdits(
          applyParents: true,
          removeParentId: 'p1',
          addParentIds: ['p3', 'p3'],
        ),
        byId: {'a': a, 'p1': p1, 'p2': p2, 'p3': p3},
      );
      expect(changed.single.parentIds, ['p2', 'p3']);
    });

    test('class membership sets and clears the class parent', () {
      const classFacet = ClassFacet();
      final math = _node('math', classFacet: classFacet);
      final art = _node('art', classFacet: classFacet);
      final work = _node('work', parents: const ['art'], classNodeId: 'art');
      final byId = {'math': math, 'art': art, 'work': work};

      final set = applyBulkEdits(
        [work],
        const NodeBulkEdits(applyClass: true, classNodeId: 'math'),
        byId: byId,
      ).single;
      expect(set.classNodeId, 'math');
      expect(set.classId, 'math');
      expect(set.classLabel, 'math');
      expect(set.parentIds, ['math']);

      final cleared = applyBulkEdits(
        [set],
        const NodeBulkEdits(applyClass: true),
        byId: {...byId, 'work': set},
      ).single;
      expect(cleared.classNodeId, isNull);
      expect(cleared.classId, isNull);
      expect(cleared.classLabel, isNull);
      expect(cleared.parentIds, isEmpty);
    });

    test('due date preserves a calendar block; blank effort clears', () {
      final a = _node(
        'a',
        schedule: ScheduleFacet(
          due: DateTime(2026, 1, 1),
          start: DateTime(2026, 1, 2, 9),
          end: DateTime(2026, 1, 2, 10),
          isFixed: true,
        ),
        effort: const EffortFacet(targetMinutes: 30),
      );
      final changed = applyBulkEdits(
        [a],
        NodeBulkEdits(
          applyDue: true,
          due: DateTime(2026, 3, 4),
          applyEffort: true,
        ),
        byId: {'a': a},
      ).single;
      expect(changed.schedule?.due, DateTime(2026, 3, 4));
      expect(changed.schedule?.start, DateTime(2026, 1, 2, 9));
      expect(changed.schedule?.end, DateTime(2026, 1, 2, 10));
      expect(changed.schedule?.isFixed, isTrue);
      expect(changed.effort, isNull);
    });

    test('unbounded drops facets and clears the task flag', () {
      final a = _node(
        'a',
        schedule: ScheduleFacet(due: DateTime(2026, 1, 1)),
        money: const MoneyFacet(targetAmount: 10),
        effort: const EffortFacet(targetMinutes: 30),
        anki: const AnkiFacet(targetReviews: 10),
        recurrence: const NodeRecurrence(frequency: TimeScale.daily),
        rule: const RuleFacet(kind: NodeRuleKind.homeworkAhead),
        taskFlag: true,
        isFavorite: false,
      );
      final changed = applyBulkEdits(
        [a],
        const NodeBulkEdits(unbounded: true, favorite: true),
        byId: {'a': a},
      ).single;
      expect(changed.isUnbounded, isTrue);
      expect(changed.isFavorite, isTrue);
      expect(changed.taskFlag, isNull);
      expect(changed.schedule, isNull);
      expect(changed.money, isNull);
      expect(changed.effort, isNull);
      expect(changed.anki, isNull);
      expect(changed.recurrence, isNull);
      expect(changed.rule, isNull);
      expect(changed.metrics, isEmpty);
    });

    test('unchanged goals are omitted from the write batch', () {
      final a = _node('a', notes: 'same', isFavorite: true);
      final changed = applyBulkEdits(
        [a],
        const NodeBulkEdits(applyNotes: true, notes: 'same', favorite: true),
        byId: {'a': a},
      );
      expect(changed, isEmpty);
    });

    test('tracks recorded sessions untouched', () {
      final a = _node('a').copyWith(
        sessions: [
          TimeSession(
            id: 'ts:1',
            start: DateTime(2026, 1, 1),
            end: DateTime(2026, 1, 1, 1),
          ),
        ],
      );
      final changed = applyBulkEdits(
        [a],
        const NodeBulkEdits(applyNotes: true, notes: 'n'),
        byId: {'a': a},
      ).single;
      expect(changed.recordedSessions, a.recordedSessions);
    });
  });
}
