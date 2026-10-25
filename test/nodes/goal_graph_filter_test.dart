import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/goal_graph_filter.dart';
import 'package:flutter_test/flutter_test.dart';

final _created = DateTime(2026, 1, 1);
final _now = DateTime(2026, 10, 14, 10); // Wednesday

Node node(
  String id, {
  List<String> parents = const [],
  DateTime? due,
  DateTime? start,
  DateTime? end,
  NodeStatus status = NodeStatus.open,
  bool favorite = false,
  bool unbounded = false,
  MoneyFacet? money,
  EffortFacet? effort,
  AnkiFacet? anki,
  AutoFacet? auto,
  NodeRecurrence? recurrence,
  String? instanceOf,
  String? sourceEventId,
}) => Node(
  id: id,
  title: id,
  parentIds: parents,
  createdAt: _created,
  status: status,
  isFavorite: favorite,
  isUnbounded: unbounded,
  schedule: (due == null && start == null && end == null)
      ? null
      : ScheduleFacet(due: due, start: start, end: end),
  money: money,
  effort: effort,
  anki: anki,
  auto: auto,
  recurrence: recurrence,
  instanceOfId: instanceOf,
  sourceEventId: sourceEventId,
);

void main() {
  group('date filters', () {
    final nodes = [
      node('overdue', due: DateTime(2026, 10, 9)),
      node('doneOverdue', due: DateTime(2026, 10, 9), status: NodeStatus.done),
      node('today', due: DateTime(2026, 10, 14, 17)),
      node('monday', due: DateTime(2026, 10, 12)),
      node('later', due: DateTime(2026, 10, 20)),
      node(
        'scheduledToday',
        start: DateTime(2026, 10, 14, 9),
        end: DateTime(2026, 10, 14, 10),
      ),
      node('noDate'),
    ];

    Set<String> matched(GoalGraphFilter filter) =>
        filterGoalGraph(nodes: nodes, now: _now, filter: filter).matchedIds;

    test('overdue ignores done goals', () {
      expect(matched(const GoalGraphFilter(date: GoalDateFilter.overdue)), {
        'overdue',
        'monday',
      });
    });

    test('today matches due and calendar block days', () {
      expect(matched(const GoalGraphFilter(date: GoalDateFilter.today)), {
        'today',
        'scheduledToday',
      });
    });

    test('this week is Monday through Sunday', () {
      expect(matched(const GoalGraphFilter(date: GoalDateFilter.thisWeek)), {
        'today',
        'monday',
        'scheduledToday',
      });
    });

    test('this month covers the whole month', () {
      expect(matched(const GoalGraphFilter(date: GoalDateFilter.thisMonth)), {
        'overdue',
        'doneOverdue',
        'today',
        'monday',
        'later',
        'scheduledToday',
      });
    });

    test('no date only matches goals without a schedule', () {
      expect(matched(const GoalGraphFilter(date: GoalDateFilter.noDate)), {
        'noDate',
      });
    });
  });

  group('kind, status, and starred filters', () {
    final nodes = [
      node('task', due: DateTime(2026, 10, 14)),
      node('money', money: const MoneyFacet(targetAmount: 100, isFixed: true)),
      node('effort', effort: const EffortFacet(targetMinutes: 60)),
      node(
        'habit',
        recurrence: const NodeRecurrence(frequency: TimeScale.daily),
      ),
      node('auto', auto: const AutoFacet(target: 120)),
      node('homework', sourceEventId: 'event:1'),
      node('anki', anki: const AnkiFacet(targetReviews: 20)),
      node('unbounded', unbounded: true),
      node('done', status: NodeStatus.done),
      node('failed', status: NodeStatus.failed),
      node('starred', favorite: true),
    ];

    Set<String> matched(GoalGraphFilter filter) =>
        filterGoalGraph(nodes: nodes, now: _now, filter: filter).matchedIds;

    test('kinds split by facet', () {
      expect(matched(const GoalGraphFilter(kind: GoalKindFilter.task)), {
        'task',
      });
      expect(matched(const GoalGraphFilter(kind: GoalKindFilter.money)), {
        'money',
      });
      expect(matched(const GoalGraphFilter(kind: GoalKindFilter.time)), {
        'effort',
      });
      expect(matched(const GoalGraphFilter(kind: GoalKindFilter.repeating)), {
        'habit',
      });
      expect(matched(const GoalGraphFilter(kind: GoalKindFilter.automated)), {
        'auto',
      });
      expect(matched(const GoalGraphFilter(kind: GoalKindFilter.homework)), {
        'homework',
      });
      expect(matched(const GoalGraphFilter(kind: GoalKindFilter.anki)), {
        'anki',
      });
      expect(matched(const GoalGraphFilter(kind: GoalKindFilter.unbounded)), {
        'unbounded',
      });
    });

    test('status and starred combine with kinds', () {
      expect(
        matched(
          const GoalGraphFilter(status: NodeStatus.failed, starredOnly: true),
        ),
        isEmpty,
      );
      expect(matched(const GoalGraphFilter(status: NodeStatus.done)), {'done'});
      expect(matched(const GoalGraphFilter(starredOnly: true)), {'starred'});
    });
  });

  group('topic branch filter', () {
    final nodes = [
      node('life'),
      node('school', parents: ['life']),
      node('math', parents: ['school']),
      node('essay', parents: ['school']),
      node('money', parents: ['life']),
      node('groceries', parents: ['money']),
    ];

    test('keeps the whole branch and its ancestors', () {
      final result = filterGoalGraph(
        nodes: nodes,
        now: _now,
        filter: const GoalGraphFilter(topicRootId: 'school'),
      );
      expect(result.matchedIds, {'school', 'math', 'essay'});
      expect(result.contextIds, {'life'});
      expect(result.visibleIds, {'life', 'school', 'math', 'essay'});
      expect(result.filterActive, isTrue);
    });

    test('shared goals match every root they hang from', () {
      final shared = [
        node('a'),
        node('b'),
        node('both', parents: ['a', 'b']),
      ];
      final byA = filterGoalGraph(
        nodes: shared,
        now: _now,
        filter: const GoalGraphFilter(topicRootId: 'a'),
      );
      final byB = filterGoalGraph(
        nodes: shared,
        now: _now,
        filter: const GoalGraphFilter(topicRootId: 'b'),
      );
      expect(byA.matchedIds, {'a', 'both'});
      expect(byB.matchedIds, {'b', 'both'});
    });

    test('goalTopicOptions lists root and branching goals', () {
      final roots = goalTopicOptions(nodes).map((n) => n.id).toList();
      expect(roots, ['life', 'money', 'school']);
    });
  });

  test('filter keeps only matched goals plus their ancestor chain', () {
    final nodes = [
      node('root'),
      node('mid', parents: ['root']),
      node('leaf', parents: ['mid'], due: DateTime(2026, 10, 14)),
      node('sibling', parents: ['root'], due: DateTime(2026, 10, 14)),
      node('unrelated'),
    ];
    final result = filterGoalGraph(
      nodes: nodes,
      now: _now,
      filter: const GoalGraphFilter(date: GoalDateFilter.today),
    );
    expect(result.matchedIds, {'leaf', 'sibling'});
    expect(result.contextIds, {'root', 'mid'});
    expect(result.visibleIds, {'root', 'mid', 'leaf', 'sibling'});
  });

  test('search alone keeps descendants and marks only matches', () {
    final nodes = [
      node('root'),
      node('alpha', parents: ['root']),
      node('child', parents: ['alpha']),
      node('other', parents: ['root']),
    ];
    final result = filterGoalGraph(nodes: nodes, now: _now, query: 'alpha');
    expect(result.matchedIds, {'alpha'});
    expect(result.visibleIds, {'root', 'alpha', 'child'});
    expect(result.contextIds, isEmpty);
    expect(result.filterActive, isFalse);
  });

  test('filter and query intersect', () {
    final nodes = [
      node('root'),
      node('alpha', parents: ['root'], due: DateTime(2026, 10, 14)),
      node('beta', parents: ['root'], due: DateTime(2026, 10, 14)),
    ];
    final result = filterGoalGraph(
      nodes: nodes,
      now: _now,
      filter: const GoalGraphFilter(date: GoalDateFilter.today),
      query: 'alpha',
    );
    expect(result.matchedIds, {'alpha'});
    expect(result.visibleIds, {'root', 'alpha'});
    expect(result.contextIds, {'root'});
  });

  test('unfiltered projection renders every goal with no restriction', () {
    final nodes = [node('a'), node('b')];
    final result = filterGoalGraph(nodes: nodes, now: _now);
    expect(result.active, isFalse);
    expect(result.filterActive, isFalse);
    expect(result.visibleIds, {'a', 'b'});
    expect(result.contextIds, isEmpty);
  });

  test('filter value equality supports page state', () {
    const a = GoalGraphFilter(
      date: GoalDateFilter.today,
      kind: GoalKindFilter.money,
      status: NodeStatus.open,
      starredOnly: true,
      topicRootId: 'school',
    );
    const b = GoalGraphFilter(
      date: GoalDateFilter.today,
      kind: GoalKindFilter.money,
      status: NodeStatus.open,
      starredOnly: true,
      topicRootId: 'school',
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a.activeCount, 5);
    expect(a.withoutDate().date, GoalDateFilter.any);
    expect(a.withoutTopic().topicRootId, isNull);
  });
}
