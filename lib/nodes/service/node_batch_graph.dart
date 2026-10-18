import '../model/node.dart';

/// Result of applying a batch of node writes to the current graph.
class NodeBatchGraphResult {
  final List<Node> upserts;
  final Set<String> removeIds;
  final Map<String, String> errors;

  const NodeBatchGraphResult({
    required this.upserts,
    required this.removeIds,
    required this.errors,
  });
}

/// Validates parent links against the graph after a batch is applied.
///
/// Parent and child nodes may be introduced together. Invalid upserts are
/// skipped while independent writes can still proceed. A removal is retained
/// only if no remaining node depends on that id.
NodeBatchGraphResult validateNodeBatchGraph({
  required List<Node> current,
  required List<Node> upserts,
  required Set<String> removeIds,
}) {
  final errors = <String, String>{};
  final candidates = <String, Node>{};
  for (final node in upserts) {
    candidates[node.id] = node;
  }
  final removals = {...removeIds};

  // Retry after rejecting bad drafts. A newly rejected parent can expose a
  // dangling link in another draft, so the projected graph must be checked
  // until it reaches a stable set of writes.
  var changed = true;
  while (changed) {
    changed = false;
    final projected = <String, Node>{
      for (final node in current)
        if (!removals.contains(node.id)) node.id: node,
    };
    projected.addAll(candidates);

    for (final node in projected.values.toList(growable: false)) {
      for (final parentId in node.parentIds) {
        if (projected.containsKey(parentId)) continue;
        if (candidates.remove(node.id) != null) {
          errors[node.id] = 'Parent node not found.';
          changed = true;
        } else if (removals.contains(parentId)) {
          // A removal that leaves a dangling child is refused. This also
          // keeps the already-persisted child reachable and intact.
          removals.remove(parentId);
          errors[parentId] = 'Cannot remove a node that still has children.';
          changed = true;
        }
        break;
      }
    }

    final cycleIds = _cycleMembers(projected);
    for (final id in cycleIds) {
      if (candidates.remove(id) != null) {
        errors[id] = 'That parent would create a cycle.';
        changed = true;
      }
    }
  }

  return NodeBatchGraphResult(
    upserts: candidates.values.toList(),
    removeIds: removals,
    errors: errors,
  );
}

Set<String> _cycleMembers(Map<String, Node> graph) {
  final visited = <String>{};
  final active = <String>{};
  final cycles = <String>{};
  final stack = <String>[];

  void visit(String id) {
    if (visited.contains(id)) return;
    if (!active.add(id)) {
      final start = stack.indexOf(id);
      if (start >= 0) cycles.addAll(stack.skip(start));
      return;
    }
    stack.add(id);
    for (final parentId in graph[id]?.parentIds ?? const <String>[]) {
      if (graph.containsKey(parentId)) visit(parentId);
    }
    stack.removeLast();
    active.remove(id);
    visited.add(id);
  }

  for (final id in graph.keys) {
    visit(id);
  }
  return cycles;
}
