import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/auto_goal.dart';
import 'package:a_fish_in_sea/nodes/service/class_membership.dart';
import 'package:a_fish_in_sea/nodes/service/goal_completion.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 10, 25, 12);

Node _node(
  String id, {
  List<String> parents = const [],
  AutoFacet? auto,
  List<AutoFacet> extraMetrics = const [],
  ClassFacet? classFacet,
  String? classNodeId,
  String? feedId,
  String? classId,
  String? classLabel,
  String? sourceEventId,
  NodeStatus status = NodeStatus.open,
  DateTime? completedAt,
  DateTime? actualStart,
  DateTime? actualEnd,
}) => Node(
  id: id,
  title: id,
  parentIds: parents,
  auto: auto,
  extraMetrics: extraMetrics,
  classFacet: classFacet,
  classNodeId: classNodeId,
  feedId: feedId,
  classId: classId,
  classLabel: classLabel,
  sourceEventId: sourceEventId,
  status: status,
  completedAt: completedAt,
  actualStart: actualStart,
  actualEnd: actualEnd,
  createdAt: DateTime(2026, 10, 1),
);

void main() {
  group('class nodes', () {
    test('a class metric sees both feed work and manual class work', () {
      final cls = _node(
        'cmlit',
        classFacet: const ClassFacet(
          sources: [ClassSource(feedId: 'feed:ls', classLabel: 'CMLIT 201')],
        ),
        auto: const AutoFacet(metric: AutoMetric.allDone),
      );
      final imported = _node(
        'essay',
        feedId: 'feed:ls',
        classId: 'feed:ls',
        classLabel: 'CMLIT 201',
        sourceEventId: 'event:essay',
        status: NodeStatus.done,
        completedAt: DateTime(2026, 10, 20),
      );
      final manual = _node(
        'review',
        parents: const ['cmlit'],
        classNodeId: 'cmlit',
        status: NodeStatus.done,
        completedAt: DateTime(2026, 10, 21),
      );
      final unrelated = _node(
        'math',
        feedId: 'feed:canvas',
        classLabel: 'MATH 290',
        sourceEventId: 'event:math',
        status: NodeStatus.open,
      );

      final reading = evaluateAutoGoal(
        cls,
        now: _now,
        nodes: [cls, imported, manual, unrelated],
      );
      expect(reading.totalCount, 2);
      expect(reading.doneCount, 2);
      expect(reading.satisfied, isTrue);
      expect(reading.progress, 1.0);
    });

    test('attachClassMembership is idempotent and parents by source', () {
      final cls = _node(
        'cmlit',
        classFacet: const ClassFacet(
          sources: [ClassSource(feedId: 'feed:ls', classLabel: 'CMLIT 201')],
        ),
        auto: const AutoFacet(metric: AutoMetric.allDone),
      );
      final imported = _node(
        'essay',
        feedId: 'feed:ls',
        classId: 'feed:ls',
        classLabel: 'CMLIT 201',
        sourceEventId: 'event:essay',
      );
      final once = attachClassMembership([cls, imported]);
      final attached = once.firstWhere((n) => n.id == 'essay');
      expect(attached.classNodeId, 'cmlit');
      expect(attached.parentIds, contains('cmlit'));
      expect(identical(attachClassMembership(once), once), isTrue);
    });
  });

  group('multiple metrics', () {
    test('all metrics must pass; the first drives the bar', () {
      final goal = _node(
        'scripture',
        auto: const AutoFacet(metric: AutoMetric.allDone),
        extraMetrics: const [AutoFacet(metric: AutoMetric.minutes, target: 60)],
      );
      final task = _node(
        'study',
        parents: const ['scripture'],
        status: NodeStatus.done,
        completedAt: _now,
        actualStart: _now.subtract(const Duration(minutes: 30)),
        actualEnd: _now,
      );
      final readings = metricReadingsForNodes([goal, task], now: _now);
      final combined = readings['scripture']!;
      expect(combined.readings, hasLength(2));
      expect(combined.primary!.facet.metric, AutoMetric.allDone);
      expect(combined.primary!.satisfied, isTrue);
      expect(combined.readings.last.satisfied, isFalse);
      expect(combined.satisfied, isFalse);
      expect(combined.progress, 1.0);

      final completion = goalCompletionForest([goal, task], readings: readings);
      expect(completion['scripture']!.complete, isFalse);
    });

    test('adding time satisfies the second metric too', () {
      final goal = _node(
        'scripture',
        auto: const AutoFacet(metric: AutoMetric.allDone),
        extraMetrics: const [AutoFacet(metric: AutoMetric.minutes, target: 60)],
      );
      final task = _node(
        'study',
        parents: const ['scripture'],
        status: NodeStatus.done,
        completedAt: _now,
        actualStart: _now.subtract(const Duration(hours: 1)),
        actualEnd: _now,
      );
      final readings = metricReadingsForNodes([goal, task], now: _now);
      expect(readings['scripture']!.satisfied, isTrue);
      expect(
        goalCompletionForest([
          goal,
          task,
        ], readings: readings)['scripture']!.complete,
        isTrue,
      );
    });
  });

  group('derived completion', () {
    test('a container completes when every class/task completes', () {
      final homework = _node('homework');
      final cls = _node(
        'cmlit',
        parents: const ['homework'],
        auto: const AutoFacet(metric: AutoMetric.allDone),
      );
      final task = _node(
        'review',
        parents: const ['cmlit'],
        classNodeId: 'cmlit',
        status: NodeStatus.done,
        completedAt: _now,
      );
      final readings = metricReadingsForNodes([homework, cls, task], now: _now);
      final complete = goalCompletionForest([
        homework,
        cls,
        task,
      ], readings: readings);
      expect(complete['cmlit']!.complete, isTrue);
      expect(complete['homework']!.complete, isTrue);
      expect(complete['homework']!.derived, isTrue);
    });

    test('a time metric completes without ticking its event child', () {
      final goal = _node(
        'work',
        auto: const AutoFacet(metric: AutoMetric.minutes, target: 60),
      );
      final session = _node(
        'session',
        parents: const ['work'],
        actualStart: _now.subtract(const Duration(hours: 1)),
        actualEnd: _now,
      );
      final readings = metricReadingsForNodes([goal, session], now: _now);
      final completion = goalCompletionForest([
        goal,
        session,
      ], readings: readings);
      expect(completion['work']!.complete, isTrue);
    });

    test('a new open assignment reopens the class and parent', () {
      final homework = _node('homework');
      final cls = _node(
        'cmlit',
        parents: const ['homework'],
        auto: const AutoFacet(metric: AutoMetric.allDone),
      );
      final done = _node(
        'done',
        parents: const ['cmlit'],
        classNodeId: 'cmlit',
        status: NodeStatus.done,
        completedAt: _now,
      );
      final open = _node(
        'open',
        parents: const ['cmlit'],
        classNodeId: 'cmlit',
      );
      final nodes = [homework, cls, done, open];
      final readings = metricReadingsForNodes(nodes, now: _now);
      final complete = goalCompletionForest(nodes, readings: readings);
      expect(complete['cmlit']!.complete, isFalse);
      expect(complete['homework']!.complete, isFalse);
    });

    test('checklist leaves keep stored completion', () {
      final leaf = _node('leaf', status: NodeStatus.done, completedAt: _now);
      final complete = goalCompletionForest([leaf]);
      expect(complete['leaf']!.derived, isFalse);
      expect(complete['leaf']!.complete, isTrue);
    });
  });

  group('model', () {
    test('class identity and extra metrics round-trip', () {
      final node = _node(
        'cmlit',
        classFacet: const ClassFacet(
          sources: [ClassSource(feedId: 'feed:ls', classLabel: 'CMLIT 201')],
        ),
        auto: const AutoFacet(metric: AutoMetric.allDone),
        extraMetrics: const [
          AutoFacet(metric: AutoMetric.minutes, target: 300),
        ],
        classNodeId: 'cmlit',
      );
      expect(Node.fromJson(node.toJson()), node);
      expect(Node.fromJson(node.toJson()).metrics, hasLength(2));
    });

    test('a legacy single auto payload loads as one metric', () {
      final node = _node('legacy', auto: const AutoFacet(target: 420));
      final json = node.toJson()
        ..remove('metrics')
        ..remove('extraMetrics');
      final loaded = Node.fromJson(json);
      expect(loaded.metrics, hasLength(1));
      expect(loaded.metrics.single.target, 420);
    });
  });
}
