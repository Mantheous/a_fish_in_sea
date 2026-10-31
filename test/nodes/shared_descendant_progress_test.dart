import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_progress.dart';
import 'package:flutter_test/flutter_test.dart';

Node _node(
  String id, {
  List<String> parents = const [],
  String? facet,
  int target = 0,
  int actual = 0,
}) {
  final start = DateTime(2026, 10, 31, 9);
  return Node(
    id: id,
    title: id,
    parentIds: parents,
    createdAt: start,
    effort: facet == 'time' ? EffortFacet(targetMinutes: target) : null,
    actualStart: facet == 'time' ? start : null,
    actualEnd: facet == 'time' ? start.add(Duration(minutes: actual)) : null,
    money: facet == 'money'
        ? MoneyFacet(
            targetAmount: target.toDouble(),
            actualAmount: actual.toDouble(),
          )
        : null,
    anki: facet == 'anki'
        ? AnkiFacet(targetReviews: target, reviewsActual: actual)
        : null,
  );
}

void main() {
  for (final facet in ['time', 'money', 'anki']) {
    group('$facet shared descendant progress', () {
      List<Node> diamond({int? rootTarget}) => [
        _node(
          'root',
          facet: rootTarget == null ? null : facet,
          target: rootTarget ?? 0,
        ),
        _node('a', parents: ['root']),
        _node('b', parents: ['root']),
        _node(
          'shared',
          parents: ['a', 'b'],
          facet: facet,
          target: 60,
          actual: 30,
        ),
      ];

      test('inferred target counts a shared task once for every ancestor', () {
        final nodes = diamond();
        for (final ordered in [nodes, nodes.reversed.toList()]) {
          final progress = progressForest(ordered);
          for (final id in ['root', 'a', 'b', 'shared']) {
            expect(progress[id], 0.5, reason: id);
          }
        }
      });

      test('explicit parent target still wins over descendant targets', () {
        final progress = progressForest(diamond(rootTarget: 120));
        expect(progress['root'], 0.25);
        expect(progress['a'], 0.5);
        expect(progress['b'], 0.5);
      });

      if (facet != 'money') {
        test('zero parent target still infers descendant targets', () {
          expect(progressForest(diamond(rootTarget: 0))['root'], 0.5);
        });
      }

      test('distinct sibling targets are still included', () {
        final nodes = [
          ...diamond(),
          _node('other', parents: ['a'], facet: facet, target: 60),
        ];
        final progress = progressForest(nodes);
        expect(progress['root'], 0.25);
        expect(progress['a'], 0.25);
        expect(progress['b'], 0.5);
      });

      test('a target reached directly and through a child counts once', () {
        final nodes = diamond();
        nodes[nodes.length - 1] = nodes.last.copyWith(
          parentIds: ['root', 'a', 'b'],
        );
        expect(progressForest(nodes)['root'], 0.5);
      });
    });
  }
}
