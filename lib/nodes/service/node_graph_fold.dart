import '../model/node.dart';

/// A goal with more direct subgoals than this starts collapsed, so one wide
/// parent cannot fill the first screen with its children.
const int kGraphAutoCollapseSubgoals = 5;

/// Default fold seed: repeating templates (their generated instances would
/// flood the canvas) plus goals whose direct fan-out exceeds
/// [kGraphAutoCollapseSubgoals].
Set<String> defaultCollapsedIds(List<Node> nodes) => {
  for (final node in nodes)
    if (node.isTemplate) node.id,
  ...wideParentIds(nodes),
};

/// Parent ids that have at least one child in [nodes].
Set<String> parentIds(List<Node> nodes) {
  final ids = {for (final node in nodes) node.id};
  final out = <String>{};
  for (final node in nodes) {
    for (final parent in node.parentIds) {
      if (ids.contains(parent)) out.add(parent);
    }
  }
  return out;
}

/// Parent ids whose direct subgoal count exceeds
/// [kGraphAutoCollapseSubgoals]. Only goals present in [nodes] count, so the
/// seed matches what the graph can actually draw.
Set<String> wideParentIds(List<Node> nodes) {
  final ids = {for (final node in nodes) node.id};
  final counts = <String, int>{};
  for (final node in nodes) {
    for (final parent in node.parentIds) {
      if (ids.contains(parent)) {
        counts[parent] = (counts[parent] ?? 0) + 1;
      }
    }
  }
  return {
    for (final entry in counts.entries)
      if (entry.value > kGraphAutoCollapseSubgoals) entry.key,
  };
}

/// True when [ancestorId] is one of [nodeId]'s ancestors in [nodes]. Walks
/// every parent (the goal tree is a DAG, so a goal can sit under more than
/// one parent).
bool hasAncestor(List<Node> nodes, String nodeId, String ancestorId) {
  final byId = {for (final node in nodes) node.id: node};
  final pending = <String>[...?byId[nodeId]?.parentIds];
  final seen = <String>{};
  while (pending.isNotEmpty) {
    final id = pending.removeLast();
    if (!seen.add(id)) continue;
    if (id == ancestorId) return true;
    pending.addAll(byId[id]?.parentIds ?? const <String>[]);
  }
  return false;
}
