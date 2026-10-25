import '../model/node.dart';

/// Applies class membership to the whole store.
///
/// Imported homework is matched by its provenance source key
/// (`(feedId, classLabel)`), and manual work by its explicit
/// [Node.classNodeId]. Both get the class node as a parent so class
/// metrics see the same scope the tree shows. Pure and idempotent: a store
/// with nothing to attach is returned unchanged.
List<Node> attachClassMembership(List<Node> nodes) {
  final bySource = <String, Node>{};
  for (final node in nodes) {
    if (!node.isClassNode) continue;
    for (final source in node.classFacet!.sources) {
      bySource.putIfAbsent(source.key, () => node);
    }
  }
  if (bySource.isEmpty) return nodes;

  final byId = {for (final node in nodes) node.id: node};
  var changed = false;
  final next = <Node>[];
  for (final node in nodes) {
    if (node.isClassNode) {
      next.add(node);
      continue;
    }
    final source = classSourceOfNode(
      feedId: node.feedId,
      classId: node.classId,
      classLabel: node.classLabel,
    );
    final explicit = node.classNodeId == null ? null : byId[node.classNodeId];
    final explicitClass = explicit != null && explicit.isClassNode
        ? explicit
        : null;
    final classNode =
        explicitClass ?? (source == null ? null : bySource[source.key]);
    if (classNode == null) {
      next.add(node);
      continue;
    }
    // Import is not a re-parent operation: only add the resolved class
    // edge. An explicit class picker/editor is where a user replaces one
    // class parent with another, with an undo record.
    final parents = [...node.parentIds];
    final needsParent = !parents.contains(classNode.id);
    final needsId = node.classNodeId != classNode.id;
    if (!needsParent && !needsId) {
      next.add(node);
      continue;
    }
    if (needsParent) parents.add(classNode.id);
    changed = true;
    next.add(
      node.copyWith(
        parentIds: parents,
        classNodeId: classNode.id,
        classLabel: node.classLabel ?? classNode.title,
      ),
    );
  }
  return changed ? next : nodes;
}
