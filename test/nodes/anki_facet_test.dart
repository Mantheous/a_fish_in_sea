import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/model/node_relations.dart';
import 'package:a_fish_in_sea/nodes/service/node_progress.dart';
import 'package:flutter_test/flutter_test.dart';

final _day = DateTime(2026, 9, 6, 9);

Node _goal(String id,
        {AnkiFacet? anki, List<String> parents = const [], NodeStatus? status}) =>
    Node(
      id: id,
      title: id,
      createdAt: _day,
      parentIds: parents,
      status: status ?? NodeStatus.open,
      anki: anki,
    );

void main() {
  group('AnkiFacet persistence', () {
    test('round-trips fully populated', () {
      final node = _goal('n1',
          anki: AnkiFacet(
            deckName: 'Japanese',
            targetReviews: 50,
            period: TimeScale.daily,
            reviewsActual: 30,
            lastSyncedAt: _day,
          ));
      expect(Node.fromJson(node.toJson()), node);
    });

    test('round-trips minimal (target only)', () {
      const facet = AnkiFacet(targetReviews: 10);
      expect(AnkiFacet.fromJson(facet.toJson()), facet);
    });

    test('pre-anki payloads load with null facet', () {
      final json = _goal('n1',
          anki: const AnkiFacet(targetReviews: 10)).toJson()
        ..remove('anki');
      expect(Node.fromJson(json).anki, isNull);
    });

    test('corrupt facet values do not drop the node', () {
      final base = _goal('n1').toJson();
      // Wrong-typed target: the facet reads as null, the node survives.
      expect(
          Node.fromJson({...base, 'anki': {'targetReviews': 'lots'}}).anki,
          isNull);
      // Non-map facet: ignored.
      expect(Node.fromJson({...base, 'anki': 'garbage'}).anki, isNull);
      // Unknown period falls back (monthly, like MoneyFacet), bad date
      // and blank deck read as null.
      final fallback = Node.fromJson({
        ...base,
        'anki': {
          'targetReviews': 10,
          'period': 'renamed-value',
          'deckName': '   ',
          'lastSyncedAt': 'not-a-date',
          'reviewsActual': -5,
        },
      }).anki!;
      expect(fallback.period, TimeScale.monthly);
      expect(fallback.deckName, isNull);
      expect(fallback.lastSyncedAt, isNull);
      expect(fallback.reviewsActual, 0);
    });
  });

  group('anki leaf progress', () {
    test('reviews over target, clamped above', () {
      expect(
          leafProgress(
              _goal('a', anki: const AnkiFacet(targetReviews: 100, reviewsActual: 30))),
          0.3);
      expect(
          leafProgress(
              _goal('b', anki: const AnkiFacet(targetReviews: 100, reviewsActual: 250))),
          1.0);
    });

    test('no count yet is zero, zero target is binary on done', () {
      expect(
          leafProgress(_goal('a', anki: const AnkiFacet(targetReviews: 10))),
          0.0);
      expect(
          leafProgress(_goal('a',
              anki: const AnkiFacet(targetReviews: 0),
              status: NodeStatus.done)),
          1.0);
      expect(
          leafProgress(
              _goal('a', anki: const AnkiFacet(targetReviews: 0))),
          0.0);
    });

    test('unbounded nodes with an anki facet fail validation', () {
      final bad = Node(
        id: 'u',
        title: 'u',
        createdAt: _day,
        isUnbounded: true,
        anki: const AnkiFacet(targetReviews: 10),
      );
      expect(validateUnbounded(bad), isNotNull);
      expect(
          validateUnbounded(
              _goal('ok', anki: const AnkiFacet(targetReviews: 10))),
          isNull);
    });
  });

  group('anki forest aggregation', () {
    test('parent target fills from children cached counts', () {
      final nodes = [
        _goal('p', anki: const AnkiFacet(targetReviews: 100)),
        _goal('a',
            anki: const AnkiFacet(targetReviews: 10, reviewsActual: 30),
            parents: ['p']),
        _goal('b',
            anki: const AnkiFacet(targetReviews: 10, reviewsActual: 40),
            parents: ['p']),
      ];
      expect(progressForest(nodes)['p'], 0.7);
    });

    test('plain parent averages anki children', () {
      final nodes = [
        _goal('p'),
        _goal('a',
            anki: const AnkiFacet(targetReviews: 10, reviewsActual: 10),
            parents: ['p']),
        _goal('b',
            anki: const AnkiFacet(targetReviews: 10, reviewsActual: 0),
            parents: ['p']),
      ];
      expect(progressForest(nodes)['p'], 0.5);
    });

    test('ankiActualForNode sums the subtree cache', () {
      final nodes = [
        _goal('p', anki: const AnkiFacet(targetReviews: 100)),
        _goal('a',
            anki: const AnkiFacet(targetReviews: 10, reviewsActual: 30),
            parents: ['p']),
        _goal('b',
            anki: const AnkiFacet(targetReviews: 10, reviewsActual: 40),
            parents: ['p']),
      ];
      expect(ankiActualForNode(nodes.first, nodes), 70.0);
    });
  });
}
