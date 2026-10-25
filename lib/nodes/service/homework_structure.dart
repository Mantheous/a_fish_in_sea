import '../model/node.dart';

/// One structural pass over the store: ensure a Homework container, give it
/// one class child per discovered class, and attach work to its class.
///
/// Pure and idempotent. The caller writes [upserts] in one silent emit. This
/// is deliberately additive: it creates nodes and parent edges, fills
/// denormalized class fields, and never deletes or re-parents anything.
class HomeworkStructurePlan {
  final String? homeworkId;
  final List<Node> upserts;

  const HomeworkStructurePlan({this.homeworkId, this.upserts = const []});

  bool get isEmpty => upserts.isEmpty;
}

HomeworkStructurePlan planHomeworkStructure(
  List<Node> nodes, {
  required DateTime now,
  Map<String, String> feedNames = const {},
  bool force = false,
}) {
  final working = {for (final node in nodes) node.id: node};
  final changed = <String, Node>{};
  final created = <String, Node>{};

  final imported = [
    for (final node in nodes)
      if (node.isHomework && node.sourceEventId != null && !node.isClassNode)
        node,
  ];
  final existingClasses = nodes.where((node) => node.isClassNode).toList();
  if (!force && imported.isEmpty && existingClasses.isEmpty) {
    return const HomeworkStructurePlan();
  }

  Node? homework;
  for (final node in nodes) {
    if (node.isClassNode || node.isInstance || node.isHomework) continue;
    if (node.title.toLowerCase().contains('homework')) {
      homework = node;
      break;
    }
  }
  if (homework == null) {
    final id = 'node:homework:${now.microsecondsSinceEpoch}';
    homework = Node(
      id: id,
      title: 'Homework',
      createdAt: now,
      // Homework means all homework work is done, including assignments
      // that have not been filed under a class yet.
      auto: const AutoFacet(
        metric: AutoMetric.allDone,
        scope: AutoScope.all,
        homeworkOnly: true,
      ),
    );
    created[id] = homework;
    working[id] = homework;
  } else if (!homework.isUnbounded && !homework.hasMetrics) {
    // Existing Homework goals predate derived completion. Give them the
    // same structural metric; users can remove it if they want a manual
    // container.
    final updated = homework.copyWith(
      auto: const AutoFacet(
        metric: AutoMetric.allDone,
        scope: AutoScope.all,
        homeworkOnly: true,
      ),
    );
    changed[homework.id] = updated;
    working[homework.id] = updated;
    homework = updated;
  }
  final homeworkId = homework.id;

  /// Put every class under Homework without removing its other parents.
  Node ensureHomeworkParent(Node cls) {
    if (cls.parentIds.contains(homeworkId)) return cls;
    final updated = cls.copyWith(parentIds: [...cls.parentIds, homeworkId]);
    changed[cls.id] = updated;
    working[cls.id] = updated;
    return updated;
  }

  for (final cls in existingClasses) {
    ensureHomeworkParent(cls);
  }

  final bySource = <String, Node>{};
  for (final cls in working.values.where((n) => n.isClassNode)) {
    for (final source in cls.classFacet!.sources) {
      bySource.putIfAbsent(source.key, () => cls);
    }
  }

  var fresh = 0;
  for (final node in imported) {
    final source = classSourceOfNode(
      feedId: node.feedId,
      classId: node.classId,
      classLabel: node.classLabel,
    );
    if (source == null || bySource.containsKey(source.key)) continue;
    final label = (node.classLabel?.trim().isNotEmpty ?? false)
        ? node.classLabel!.trim()
        : (feedNames[source.feedId]?.trim() ?? '');
    if (label.isEmpty) continue;
    // A class created by hand (CMLIT has no feed) later gets a feed: bind
    // the source to that existing node instead of creating a duplicate.
    Node? sameTitle;
    for (final cls in working.values.where((n) => n.isClassNode)) {
      if (cls.title.trim().toLowerCase() == label.toLowerCase()) {
        sameTitle = cls;
        break;
      }
    }
    if (sameTitle != null) {
      final sources = sameTitle.classFacet!.sources;
      if (!sources.any((bound) => bound.key == source.key)) {
        final updated = sameTitle.copyWith(
          classFacet: sameTitle.classFacet!.copyWith(
            sources: [...sources, source],
          ),
        );
        changed[updated.id] = updated;
        working[updated.id] = updated;
        sameTitle = updated;
      }
      bySource[source.key] = sameTitle;
      continue;
    }
    final id = 'node:class:${now.microsecondsSinceEpoch}:${fresh++}';
    final cls = Node(
      id: id,
      title: label,
      parentIds: [homeworkId],
      createdAt: now,
      classFacet: ClassFacet(sources: [source]),
      auto: const AutoFacet(metric: AutoMetric.allDone),
    );
    created[id] = cls;
    working[id] = cls;
    bySource[source.key] = cls;
  }

  /// Class membership is a parent edge. Normalize the denormalized fields
  /// so the Homework tab, filters, and stats all agree.
  for (final node in nodes) {
    if (node.isClassNode) continue;
    Node? cls;
    if (node.classNodeId != null) {
      final explicit = working[node.classNodeId];
      if (explicit != null && explicit.isClassNode) cls = explicit;
    }
    if (cls == null) {
      for (final parent in node.parentIds) {
        final candidate = working[parent];
        if (candidate != null && candidate.isClassNode) {
          cls = candidate;
          break;
        }
      }
    }
    if (cls == null) {
      final source = classSourceOfNode(
        feedId: node.feedId,
        classId: node.classId,
        classLabel: node.classLabel,
      );
      cls = source == null ? null : bySource[source.key];
    }
    if (cls == null) continue;
    final parents = [...node.parentIds];
    // Instances must keep exactly one parent (their template). Class
    // membership still travels through classNodeId.
    if (!node.isInstance && !parents.contains(cls.id)) parents.add(cls.id);
    final isImported = node.sourceEventId != null || node.feedId != null;
    final classId = isImported ? node.classId : cls.id;
    final classLabel = node.classLabel ?? cls.title;
    if (node.classNodeId == cls.id &&
        node.classId == classId &&
        node.classLabel == classLabel &&
        _sameList(parents, node.parentIds)) {
      continue;
    }
    final updated = node.copyWith(
      parentIds: parents,
      classNodeId: cls.id,
      classId: classId,
      classLabel: classLabel,
    );
    changed[node.id] = updated;
    working[node.id] = updated;
  }

  final upserts = <Node>[
    ...created.values,
    ...changed.values.where((node) => !created.containsKey(node.id)),
  ];
  return HomeworkStructurePlan(homeworkId: homeworkId, upserts: upserts);
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
