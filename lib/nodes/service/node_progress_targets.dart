part of 'node_progress.dart';

double _subtreeMoneyTarget(
  String id,
  Map<String, Node> byId,
  Map<String, List<Node>> byParent,
  Set<String> seen,
) {
  if (!seen.add(id)) return 0.0;
  final node = byId[id];
  if (node == null) return 0.0;
  var total = node.money?.effectiveTarget ?? 0.0;
  for (final kid in byParent[id] ?? const <Node>[]) {
    total += _subtreeMoneyTarget(kid.id, byId, byParent, seen);
  }
  return total;
}

double _subtreeEffortTarget(
  String id,
  Map<String, Node> byId,
  Map<String, List<Node>> byParent,
  Set<String> seen,
) {
  if (!seen.add(id)) return 0.0;
  final node = byId[id];
  if (node == null) return 0.0;
  var total = (node.effort?.targetMinutes ?? 0).toDouble();
  for (final kid in byParent[id] ?? const <Node>[]) {
    total += _subtreeEffortTarget(kid.id, byId, byParent, seen);
  }
  return total;
}

double _subtreeAnkiTarget(
  String id,
  Map<String, Node> byId,
  Map<String, List<Node>> byParent,
  Set<String> seen,
) {
  if (!seen.add(id)) return 0.0;
  final node = byId[id];
  if (node == null) return 0.0;
  var total = (node.anki?.targetReviews ?? 0).toDouble();
  for (final kid in byParent[id] ?? const <Node>[]) {
    total += _subtreeAnkiTarget(kid.id, byId, byParent, seen);
  }
  return total;
}
