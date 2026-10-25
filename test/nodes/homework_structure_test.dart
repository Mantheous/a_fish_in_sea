import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/auto_goal.dart';
import 'package:a_fish_in_sea/nodes/service/homework_structure.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 10, 25, 12);

Node _node(
  String id, {
  String? title,
  List<String> parents = const [],
  AutoFacet? auto,
  ClassFacet? classFacet,
  String? classNodeId,
  String? feedId,
  String? classId,
  String? classLabel,
  String? sourceEventId,
  NodeStatus status = NodeStatus.open,
  DateTime? completedAt,
}) => Node(
  id: id,
  title: title ?? id,
  parentIds: parents,
  auto: auto,
  classFacet: classFacet,
  classNodeId: classNodeId,
  feedId: feedId,
  classId: classId,
  classLabel: classLabel,
  sourceEventId: sourceEventId,
  status: status,
  completedAt: completedAt,
  createdAt: _now,
);

List<Node> _apply(List<Node> nodes, HomeworkStructurePlan plan) {
  final byId = {for (final node in nodes) node.id: node};
  for (final node in plan.upserts) {
    byId[node.id] = node;
  }
  return byId.values.toList();
}

void main() {
  test('auto-creates Homework and one class child per imported class', () {
    final nodes = [
      _node(
        'cmlit-essay',
        title: 'Essay 1',
        feedId: 'feed:ls',
        classId: 'feed:ls',
        classLabel: 'CMLIT 201',
        sourceEventId: 'e1',
      ),
      _node(
        'math-set',
        title: 'Problem set',
        feedId: 'feed:ls',
        classId: 'feed:ls',
        classLabel: 'MATH 290',
        sourceEventId: 'e2',
      ),
    ];
    final plan = planHomeworkStructure(
      nodes,
      now: _now,
      feedNames: const {'feed:ls': 'Learning Suite'},
    );
    expect(plan.homeworkId, isNotNull);
    final applied = _apply(nodes, plan);

    final homework = applied.firstWhere((n) => n.id == plan.homeworkId);
    expect(homework.title, 'Homework');
    expect(homework.parentIds, isEmpty);
    expect(homework.metrics, hasLength(1));
    expect(homework.metrics.single.metric, AutoMetric.allDone);
    expect(homework.metrics.single.scope, AutoScope.all);
    expect(homework.metrics.single.homeworkOnly, isTrue);

    final classes = applied.where((n) => n.isClassNode).toList();
    expect(classes.map((n) => n.title).toSet(), {'CMLIT 201', 'MATH 290'});
    for (final cls in classes) {
      expect(cls.parentIds, contains(homework.id));
      expect(cls.metrics.single.metric, AutoMetric.allDone);
    }

    final essay = applied.firstWhere((n) => n.id == 'cmlit-essay');
    final cmlit = classes.firstWhere((n) => n.title == 'CMLIT 201');
    expect(essay.classNodeId, cmlit.id);
    expect(essay.parentIds, contains(cmlit.id));
    expect(essay.classLabel, 'CMLIT 201');
  });

  test('binds a feed to an existing manual class with the same title', () {
    final homework = _node('homework', title: 'Homework');
    final manual = _node(
      'cmlit',
      title: 'CMLIT 201',
      parents: const ['homework'],
      classFacet: const ClassFacet(),
      auto: const AutoFacet(metric: AutoMetric.allDone),
    );
    final imported = _node(
      'essay',
      feedId: 'feed:ls',
      classId: 'feed:ls',
      classLabel: 'CMLIT 201',
      sourceEventId: 'e1',
    );
    final applied = _apply([
      homework,
      manual,
      imported,
    ], planHomeworkStructure([homework, manual, imported], now: _now));
    final classes = applied.where((n) => n.isClassNode).toList();
    expect(classes, hasLength(1));
    expect(classes.single.id, 'cmlit');
    expect(classes.single.classFacet!.sources.single.feedId, 'feed:ls');
    expect(applied.firstWhere((n) => n.id == 'essay').classNodeId, 'cmlit');
  });

  test('uses a feed name when the imported class has no label', () {
    final canvas = _node(
      'canvas-hw',
      title: 'Problem set',
      feedId: 'feed:canvas',
      classId: 'feed:canvas',
      sourceEventId: 'e1',
    );
    final applied = _apply(
      [canvas],
      planHomeworkStructure(
        [canvas],
        now: _now,
        feedNames: const {'feed:canvas': 'MATH 290'},
      ),
    );
    final cls = applied.firstWhere((n) => n.isClassNode);
    expect(cls.title, 'MATH 290');
    expect(applied.firstWhere((n) => n.id == 'canvas-hw').classNodeId, cls.id);
  });

  test('adopts an existing class parent as class membership', () {
    final homework = _node('homework', title: 'Homework');
    final cmlit = _node(
      'cmlit',
      title: 'CMLIT 201',
      parents: const ['homework'],
      classFacet: const ClassFacet(),
      auto: const AutoFacet(metric: AutoMetric.allDone),
    );
    final review = _node(
      'review',
      title: 'Midterm review',
      parents: const ['cmlit'],
    );
    final plan = planHomeworkStructure([homework, cmlit, review], now: _now);
    final applied = _apply([homework, cmlit, review], plan);
    final adopted = applied.firstWhere((n) => n.id == 'review');
    expect(adopted.classNodeId, 'cmlit');
    expect(adopted.classId, 'cmlit');
    expect(adopted.classLabel, 'CMLIT 201');
    expect(adopted.parentIds, contains('cmlit'));
  });

  test('preserves classId-only legacy feed provenance', () {
    final homework = _node('homework', title: 'Homework');
    final cls = _node(
      'cmlit',
      title: 'CMLIT 201',
      parents: const ['homework'],
      classFacet: const ClassFacet(),
      auto: const AutoFacet(metric: AutoMetric.allDone),
    );
    final legacy = Node(
      id: 'legacy',
      title: 'Syllabus assignment',
      parentIds: const ['cmlit'],
      createdAt: _now,
      classId: 'feed:old-syllabus',
      classLabel: 'CMLIT 201',
    );
    final applied = _apply(
      [homework, cls, legacy],
      planHomeworkStructure([homework, cls, legacy], now: _now),
    );
    final saved = applied.firstWhere((n) => n.id == 'legacy');
    expect(saved.classNodeId, 'cmlit');
    expect(saved.classId, 'feed:old-syllabus');
    expect(saved.classLabel, 'CMLIT 201');
  });

  test('does not adopt a task titled Homework 3', () {
    final assignment = Node(
      id: 'hw3',
      title: 'Homework 3',
      createdAt: _now,
      schedule: ScheduleFacet(due: _now),
    );
    final imported = _node(
      'essay',
      feedId: 'feed:ls',
      classId: 'feed:ls',
      classLabel: 'CMLIT 201',
      sourceEventId: 'e1',
    );
    final applied = _apply(
      [assignment, imported],
      planHomeworkStructure([assignment, imported], now: _now),
    );
    final homework = applied.firstWhere((n) => n.title == 'Homework');
    expect(homework.id, isNot('hw3'));
    expect(
      applied.firstWhere((n) => n.id == 'hw3').parentIds,
      isEmpty,
    );
  });

  test('is idempotent once the structure exists', () {
    final nodes = [
      _node(
        'essay',
        title: 'Essay',
        feedId: 'feed:ls',
        classId: 'feed:ls',
        classLabel: 'CMLIT 201',
        sourceEventId: 'e1',
      ),
    ];
    final first = _apply(nodes, planHomeworkStructure(nodes, now: _now));
    final again = planHomeworkStructure(first, now: _now);
    expect(again.upserts, isEmpty);
    expect(again.homeworkId, isNotNull);
  });

  test('ids are deterministic across offline passes', () {
    final nodes = [
      _node(
        'essay',
        feedId: 'feed:ls',
        classId: 'feed:ls',
        classLabel: 'CMLIT 201',
        sourceEventId: 'e1',
      ),
    ];
    final first = planHomeworkStructure(nodes, now: _now);
    final second = planHomeworkStructure(
      nodes,
      now: _now.add(const Duration(seconds: 1)),
    );
    expect(first.homeworkId, second.homeworkId);
    expect(
      first.upserts.where((n) => n.isClassNode).map((n) => n.id).toSet(),
      second.upserts.where((n) => n.isClassNode).map((n) => n.id).toSet(),
    );
  });

  test('force creates Homework even before any class exists', () {
    final plan = planHomeworkStructure(const [], now: _now, force: true);
    expect(plan.homeworkId, isNotNull);
    expect(plan.upserts, hasLength(1));
    expect(plan.upserts.single.title, 'Homework');
  });

  test('auto Homework allDone counts every homework task', () {
    final nodes = [
      _node(
        'essay',
        feedId: 'feed:ls',
        classId: 'feed:ls',
        classLabel: 'CMLIT 201',
        sourceEventId: 'e1',
      ),
      _node(
        'review',
        feedId: 'feed:ls',
        classId: 'feed:ls',
        classLabel: 'CMLIT 201',
        sourceEventId: 'e2',
        status: NodeStatus.done,
        completedAt: _now,
      ),
    ];
    final applied = _apply(nodes, planHomeworkStructure(nodes, now: _now));
    final homework = applied.firstWhere((n) => n.title == 'Homework');
    final reading = evaluateAutoGoal(homework, now: _now, nodes: applied);
    expect(reading.totalCount, 2);
    expect(reading.doneCount, 1);
    expect(reading.satisfied, isFalse);
  });
}
