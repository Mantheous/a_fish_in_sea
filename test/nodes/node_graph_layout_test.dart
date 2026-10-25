import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_graph_layout.dart';
import 'package:flutter_test/flutter_test.dart';

Node goal(
  String id, {
  String? title,
  List<String> parents = const [],
  DateTime? due,
  DateTime? created,
  NodeStatus status = NodeStatus.open,
  bool unbounded = false,
}) => Node(
  id: id,
  title: title ?? id,
  parentIds: parents,
  createdAt: created ?? DateTime(2026, 1, 1),
  isUnbounded: unbounded,
  status: status,
  schedule: due == null ? null : ScheduleFacet(due: due),
);

void main() {
  group('layoutNodeGraph', () {
    test('lays out depth rows, parents centered over children', () {
      final nodes = [
        goal('root', due: DateTime(2026, 1, 1)),
        goal('a', parents: ['root'], due: DateTime(2026, 1, 2)),
        goal('b', parents: ['root'], due: DateTime(2026, 1, 3)),
        goal('c', parents: ['a'], due: DateTime(2026, 1, 4)),
      ];
      final layout = layoutNodeGraph(nodes: nodes);
      final byId = {for (final p in layout.placements) p.node.id: p};

      expect(byId.keys, containsAll(['root', 'a', 'b', 'c']));
      expect(byId['root']!.depth, 0);
      expect(byId['a']!.depth, 1);
      expect(byId['b']!.depth, 1);
      expect(byId['c']!.depth, 2);

      // Rows stack downward.
      expect(byId['root']!.rect.bottom, lessThan(byId['a']!.rect.top));
      expect(byId['a']!.rect.bottom, lessThan(byId['c']!.rect.top));

      // Due order decides sibling order.
      expect(byId['a']!.rect.center.dx, lessThan(byId['b']!.rect.center.dx));

      // Parent centered over its children; single child aligned under it.
      expect(
        byId['root']!.rect.center.dx,
        closeTo(
          (byId['a']!.rect.center.dx + byId['b']!.rect.center.dx) / 2,
          0.01,
        ),
      );
      expect(
        byId['a']!.rect.center.dx,
        closeTo(byId['c']!.rect.center.dx, 0.01),
      );

      // Canvas covers every card plus padding.
      expect(layout.size.width, greaterThanOrEqualTo(byId['b']!.rect.right));
      expect(layout.size.height, greaterThanOrEqualTo(byId['c']!.rect.bottom));

      // One connector per parent-child link, all tidy-tree edges.
      expect(layout.edges.length, 3);
      expect(layout.edges.every((e) => e.primary), isTrue);
      final pairs = layout.edges
          .map((e) => '${e.parentId}->${e.childId}')
          .toSet();
      expect(pairs, {'root->a', 'root->b', 'a->c'});
    });

    test('collapsed subtree hides descendants and counts them', () {
      final nodes = [
        goal('root'),
        goal('a', parents: ['root']),
        goal('b', parents: ['root']),
        goal('c', parents: ['a']),
        goal('d', parents: ['c']),
      ];
      final layout = layoutNodeGraph(nodes: nodes, collapsedIds: {'a'});
      final byId = {for (final p in layout.placements) p.node.id: p};

      expect(byId.keys, containsAll(['root', 'a', 'b']));
      expect(byId.containsKey('c'), isFalse);
      expect(byId.containsKey('d'), isFalse);

      final a = byId['a']!;
      expect(a.collapsed, isTrue);
      expect(a.childCount, 1, reason: 'badge button counts direct children');
      expect(a.hiddenDescendants, 2, reason: 'c and d are hidden');

      // No connector dangles into hidden space.
      expect(layout.edges.any((e) => e.childId == 'c'), isFalse);
      expect(layout.edges.any((e) => e.childId == 'd'), isFalse);
    });

    test('shared child is placed once with an edge per parent', () {
      final nodes = [
        goal('root'),
        goal('a', parents: ['root']),
        goal('b', parents: ['root']),
        goal('shared', parents: ['a', 'b']),
      ];
      final layout = layoutNodeGraph(nodes: nodes);
      expect(layout.placements.where((p) => p.node.id == 'shared').length, 1);
      final links = layout.edges.where((e) => e.childId == 'shared').toList();
      expect(links.map((e) => e.parentId).toSet(), {'a', 'b'});
      expect(links.where((e) => e.primary).length, 1);
    });

    test('shared task sits below every parent, not just the first', () {
      // `task` feeds both `a` (row 1) and `e` (row 3). Depth-first placement
      // used to claim it under `a`, leaving it level with `d` and above its
      // other parent `e`.
      final nodes = [
        goal('root', due: DateTime(2026, 1, 1)),
        goal('a', parents: ['root'], due: DateTime(2026, 1, 2)),
        goal('c', parents: ['root'], due: DateTime(2026, 1, 3)),
        goal('d', parents: ['c'], due: DateTime(2026, 1, 4)),
        goal('e', parents: ['d'], due: DateTime(2026, 1, 5)),
        goal('task', parents: ['a', 'e'], due: DateTime(2026, 1, 6)),
      ];
      final layout = layoutNodeGraph(nodes: nodes);
      final byId = {for (final p in layout.placements) p.node.id: p};

      expect(byId['root']!.depth, 0);
      expect(byId['a']!.depth, 1);
      expect(byId['c']!.depth, 1);
      expect(byId['d']!.depth, 2);
      expect(byId['e']!.depth, 3);
      expect(byId['task']!.depth, 4);
      expect(byId['task']!.placementParentId, 'e');

      // The whole DAG lays out strictly downward: no connector goes up.
      for (final edge in layout.edges) {
        final parent = byId[edge.parentId]!;
        final child = byId[edge.childId]!;
        expect(
          parent.rect.bottom,
          lessThan(child.rect.top),
          reason: '${edge.parentId} must sit above ${edge.childId}',
        );
      }
    });

    test('deep parent never ends up below a shared child', () {
      // Same DAG with the shallow parent sorted first and the deep parent
      // claimed through a different branch, so placement order cannot be
      // what keeps the rows right.
      final nodes = [
        goal('root'),
        goal('shallow', parents: ['root'], created: DateTime(2026, 1, 2)),
        goal('mid', parents: ['root'], created: DateTime(2026, 1, 3)),
        goal('deep', parents: ['mid'], created: DateTime(2026, 1, 4)),
        goal('deeper', parents: ['deep'], created: DateTime(2026, 1, 5)),
        goal('task', parents: ['shallow', 'deeper'], created: DateTime(2025, 1, 1)),
      ];
      final layout = layoutNodeGraph(nodes: nodes);
      final byId = {for (final p in layout.placements) p.node.id: p};
      expect(byId['shallow']!.depth, 1);
      expect(byId['deeper']!.depth, 3);
      expect(byId['task']!.depth, 4);
      for (final edge in layout.edges) {
        expect(
          byId[edge.parentId]!.rect.bottom,
          lessThan(byId[edge.childId]!.rect.top),
        );
      }
    });

    test('search filter ignores collapse so matches stay reachable', () {
      final nodes = [
        goal('root'),
        goal('a', parents: ['root']),
        goal('b', parents: ['root']),
        goal('c', parents: ['a']),
      ];
      final layout = layoutNodeGraph(
        nodes: nodes,
        collapsedIds: {'a'},
        visibleIds: {'root', 'a', 'c'},
      );
      final byId = {for (final p in layout.placements) p.node.id: p};
      expect(byId.keys, containsAll(['root', 'a', 'c']));
      expect(byId.containsKey('b'), isFalse);
      expect(byId['a']!.collapsed, isFalse);
      expect(
        layout.edges.any((e) => e.parentId == 'a' && e.childId == 'c'),
        isTrue,
      );
    });

    test('empty search result and empty input produce an empty layout', () {
      final nodes = [goal('root')];
      expect(layoutNodeGraph(nodes: const []).isEmpty, isTrue);
      expect(
        layoutNodeGraph(nodes: nodes, visibleIds: const {}).isEmpty,
        isTrue,
      );
    });

    test('compact context nodes are narrow and keep their edges', () {
      final nodes = [
        goal('root', due: DateTime(2026, 1, 1)),
        goal('mid', parents: ['root'], due: DateTime(2026, 1, 2)),
        goal('leaf', parents: ['mid'], due: DateTime(2026, 1, 3)),
      ];
      final layout = layoutNodeGraph(
        nodes: nodes,
        visibleIds: {'root', 'mid', 'leaf'},
        compactIds: {'root', 'mid'},
      );
      final byId = {for (final p in layout.placements) p.node.id: p};
      expect(byId['root']!.compact, isTrue);
      expect(byId['mid']!.compact, isTrue);
      expect(byId['leaf']!.compact, isFalse);
      expect(byId['root']!.rect.width, lessThan(byId['leaf']!.rect.width));
      expect(byId['root']!.rect.height, lessThan(byId['leaf']!.rect.height));
      // Compact markers sit on the same row, centered between the rows.
      expect(
        byId['root']!.rect.center.dy,
        lessThan(byId['mid']!.rect.center.dy),
      );
      // Path edges are still drawn, just faint.
      final path = layout.edges
          .where((e) => e.childId == 'mid' || e.childId == 'leaf')
          .toList();
      expect(path.length, 2);
      expect(path.every((e) => e.faint), isTrue);
    });

    test('cycle without roots still lays out every node once', () {
      final nodes = [
        goal('a', parents: ['b']),
        goal('b', parents: ['a']),
      ];
      final layout = layoutNodeGraph(nodes: nodes);
      expect(layout.placements.length, 2);
      expect(layout.placements.map((p) => p.node.id).toSet(), {'a', 'b'});
    });

    test('layout is deterministic for the same input', () {
      final nodes = [
        goal('root'),
        goal('a', parents: ['root'], created: DateTime(2026, 2, 1)),
        goal('b', parents: ['root'], created: DateTime(2026, 2, 1)),
        goal('c', parents: ['a']),
      ];
      final first = layoutNodeGraph(nodes: nodes);
      final second = layoutNodeGraph(nodes: nodes);
      for (final p in first.placements) {
        final q = second.placements.firstWhere((e) => e.node.id == p.node.id);
        expect(q.rect, p.rect);
      }
    });
  });
}
