import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import '../model/node.dart';

/// Geometry constants for the graph view. Cards are fixed-size so the tidy
/// layout is deterministic and cheap to recompute on every rebuild; long
/// titles ellipsize inside the card instead of changing its size.
class NodeGraphStyle {
  final double nodeWidth;
  final double nodeHeight;

  /// Compact card size. Filtered-out ancestors use these so the relation
  /// stays visible without reading as a matching goal.
  final double compactWidth;
  final double compactHeight;

  /// Gap between sibling subtrees.
  final double horizontalGap;

  /// Vertical gap between depth rows.
  final double verticalGap;

  /// Gap between separate (rooted) trees.
  final double rootGap;

  /// Canvas margin around the whole layout.
  final double padding;

  const NodeGraphStyle({
    this.nodeWidth = 176,
    this.nodeHeight = 62,
    this.compactWidth = 112,
    this.compactHeight = 30,
    this.horizontalGap = 26,
    this.verticalGap = 78,
    this.rootGap = 72,
    this.padding = 48,
  });
}

/// One laid-out goal card on the graph canvas.
class GraphNodePlacement {
  final Node node;

  /// Canvas-space card rectangle (top-left + fixed card size).
  final Rect rect;

  /// Row in the layered layout. Roots are 0 and every child row is strictly
  /// below all of its parents, so a shared node is placed on the row after
  /// its deepest parent.
  final int depth;

  /// Parent this node is drawn under. Null for roots. A shared node is
  /// placed once, under its deepest parent; every other parent still gets a
  /// connector (see [GraphEdge.primary]).
  final String? placementParentId;

  /// Direct children in the full goal set (not just the displayed ones).
  final int childCount;

  /// Descendants hidden by collapsing this node. 0 when expanded.
  final int hiddenDescendants;

  /// True when this node hides its children.
  final bool collapsed;

  /// True for a filtered-out ancestor kept as a compact path marker.
  final bool compact;

  const GraphNodePlacement({
    required this.node,
    required this.rect,
    required this.depth,
    required this.placementParentId,
    required this.childCount,
    required this.hiddenDescendants,
    required this.collapsed,
    this.compact = false,
  });

  bool get hasChildren => childCount > 0;
}

/// A drawn connector between a parent and a displayed child.
class GraphEdge {
  final String parentId;
  final String childId;

  /// Curve endpoints: parent bottom edge, child top edge.
  final Offset start;
  final Offset end;

  /// True for the edge the layout placed the child under (the tidy-tree
  /// edge), false for extra DAG parents of a shared node.
  final bool primary;

  /// True when either endpoint is a compact filtered-out context node.
  /// The painter draws these lighter so the matched goals stand out.
  final bool faint;

  const GraphEdge({
    required this.parentId,
    required this.childId,
    required this.start,
    required this.end,
    required this.primary,
    this.faint = false,
  });
}

/// Result of [layoutNodeGraph]: canvas size plus everything to draw.
class NodeGraphLayout {
  final Size size;
  final List<GraphNodePlacement> placements;
  final List<GraphEdge> edges;

  const NodeGraphLayout({
    required this.size,
    required this.placements,
    required this.edges,
  });

  static const empty = NodeGraphLayout(
    size: Size.zero,
    placements: [],
    edges: [],
  );

  bool get isEmpty => placements.isEmpty;
}

/// Top-down tidy layout for the goal DAG, the shape of the Figma board in
/// `docs/goal-tree-issue-4.png`: roots at the top, children in deeper rows,
/// every parent centered over its children, and shared children drawn once
/// with connectors from each parent (their extra edges curve across).
///
/// Rows are longest-path depths: a node sits one row below its *deepest*
/// parent, never level with or above any parent. A task feeding several
/// goals at different levels therefore hangs under the deepest one instead
/// of appearing beside an ancestor.
///
/// Collapse: ids in [collapsedIds] hide their whole subtree; those nodes
/// still render with a badge ([GraphNodePlacement.hiddenDescendants]) so the
/// hidden part is discoverable. When [visibleIds] is non-null (search or a
/// filter), the graph shows that restricted set and collapse is ignored, so
/// a restriction never hides its matches.
///
/// Filter context: ids in [compactIds] render as compact path markers
/// instead of full cards. Callers pass the filtered-out ancestors of the
/// matches here, so a deep match still shows *what it hangs from* without
/// pretending every ancestor matched.
///
/// Pure and deterministic: no clock, no ids minted. Cycle-safe.
NodeGraphLayout layoutNodeGraph({
  required List<Node> nodes,
  Set<String> collapsedIds = const <String>{},
  Set<String>? visibleIds,
  Set<String> compactIds = const <String>{},
  NodeGraphStyle style = const NodeGraphStyle(),
}) {
  if (nodes.isEmpty) return NodeGraphLayout.empty;

  final searching = visibleIds != null;
  final allowed = searching ? visibleIds : {for (final n in nodes) n.id};
  final allowedNodes = nodes.where((n) => allowed.contains(n.id)).toList();
  if (allowedNodes.isEmpty) return NodeGraphLayout.empty;

  final byId = {for (final n in nodes) n.id: n};
  final order = {
    for (var i = 0; i < allowedNodes.length; i++) allowedNodes[i].id: i,
  };

  double widthOf(String id) =>
      compactIds.contains(id) ? style.compactWidth : style.nodeWidth;
  bool isCompact(String id) => compactIds.contains(id);

  // Children within the allowed set, sorted the way lists sort goals
  // (due date, then creation) so the same data always lays out the same.
  final children = <String, List<Node>>{};
  for (final n in allowedNodes) {
    for (final p in n.parentIds) {
      if (byId.containsKey(p)) {
        children.putIfAbsent(p, () => []).add(n);
      }
    }
  }
  for (final list in children.values) {
    list.sort(_compareGoals);
  }

  // Walk from the roots, stopping at collapsed nodes. `displayParent` keeps
  // the first parent that reached a shared node.
  final displayed = <String>{};
  final displayParent = <String, String?>{};

  void visit(String id, String? via) {
    if (!displayed.add(id)) return;
    displayParent[id] = via;
    if (!searching && collapsedIds.contains(id)) return;
    for (final kid in children[id] ?? const <Node>[]) {
      visit(kid.id, id);
    }
  }

  final roots =
      allowedNodes.where((n) => !n.parentIds.any(allowed.contains)).toList()
        ..sort((a, b) => order[a.id]!.compareTo(order[b.id]!));
  for (final root in roots) {
    visit(root.id, null);
  }
  // A closed loop has no root. DAG validation prevents cycles in practice —
  // this fallback only guarantees a cycle never renders a blank canvas.
  if (displayed.isEmpty) {
    for (final n in allowedNodes) {
      visit(n.id, null);
    }
  }

  // Row of every displayed node: one below its deepest displayed parent
  // (the longest path from any root), so a shared node can never render
  // above a goal it feeds. Depth-first placement used to put a shared task
  // under the first parent that reached it, which left it level with — or
  // above — a deeper parent that also claims it. DAG validation prevents
  // cycles; the visiting set only keeps this from recursing forever.
  final ranks = <String, int>{};
  int rankOf(String id, Set<String> visiting) {
    final cached = ranks[id];
    if (cached != null) return cached;
    if (!visiting.add(id)) return 0;
    var rank = 0;
    for (final parent in byId[id]!.parentIds) {
      if (parent == id || !displayed.contains(parent)) continue;
      final candidate = rankOf(parent, visiting) + 1;
      if (candidate > rank) rank = candidate;
    }
    visiting.remove(id);
    ranks[id] = rank;
    return rank;
  }

  for (final id in displayed.toList()) {
    rankOf(id, <String>{});
  }

  // Claim placement children: a shared node is placed under its deepest
  // parent, so its row is exactly one below that parent. Equal-rank parents
  // keep the first one that reached the node, matching the old tidy order.
  final placementParent = <String, String?>{};
  for (final id in displayed) {
    final node = byId[id]!;
    String? chosen;
    var chosenRank = -1;
    for (final parent in node.parentIds) {
      if (parent == id || !displayed.contains(parent)) continue;
      final parentRank = ranks[parent] ?? 0;
      if (parentRank > chosenRank ||
          (parentRank == chosenRank && parent == displayParent[id])) {
        chosen = parent;
        chosenRank = parentRank;
      }
    }
    placementParent[id] = chosen;
  }

  final placementChildren = <String, List<String>>{};
  final placed = <String>{};

  void collect(String id) {
    if (!placed.add(id)) return;
    final kids = <Node>[];
    for (final kid in children[id] ?? const <Node>[]) {
      if (displayed.contains(kid.id) &&
          !placed.contains(kid.id) &&
          placementParent[kid.id] == id) {
        kids.add(kid);
      }
    }
    placementChildren[id] = [for (final k in kids) k.id];
    for (final k in kids) {
      collect(k.id);
    }
  }

  final displayRoots =
      displayed.where((id) => placementParent[id] == null).toList()
        ..sort((a, b) => order[a]!.compareTo(order[b]!));
  final layoutRoots = <String>[];
  for (final root in displayRoots) {
    layoutRoots.add(root);
    collect(root);
  }
  // Defensive: a cycle-invalid graph has no placement root, so nothing above
  // reached its members. Lay them out as extra roots — a broken graph must
  // not render a blank canvas.
  for (final id in displayed) {
    if (!placed.contains(id)) {
      layoutRoots.add(id);
      collect(id);
    }
  }

  // Tidy tree sizing: a subtree is at least one card wide, otherwise the
  // span of its children. Memoized so deep chains stay linear.
  final widths = <String, double>{};
  double subtreeWidth(String id) {
    final cached = widths[id];
    if (cached != null) return cached;
    final kids = placementChildren[id] ?? const <String>[];
    final ownWidth = widthOf(id);
    var width = ownWidth;
    if (kids.isNotEmpty) {
      var span = 0.0;
      for (var i = 0; i < kids.length; i++) {
        if (i > 0) span += style.horizontalGap;
        span += subtreeWidth(kids[i]);
      }
      width = math.max(ownWidth, span);
    }
    widths[id] = width;
    return width;
  }

  double childrenSpan(List<String> kids) {
    var span = 0.0;
    for (var i = 0; i < kids.length; i++) {
      if (i > 0) span += style.horizontalGap;
      span += subtreeWidth(kids[i]);
    }
    return span;
  }

  final rects = <String, Rect>{};
  final depths = <String, int>{};
  var maxBottom = 0.0;

  void position(String id, double left, int depth) {
    final width = subtreeWidth(id);
    final ownWidth = widthOf(id);
    final kids = placementChildren[id] ?? const <String>[];
    double x;
    if (kids.isEmpty) {
      x = left + (width - ownWidth) / 2;
    } else {
      final span = childrenSpan(kids);
      var cursor = left + (width - span) / 2;
      for (final kid in kids) {
        position(kid, cursor, depth + 1);
        cursor += subtreeWidth(kid) + style.horizontalGap;
      }
      // Center over the outer children, never letting the card leave its
      // own subtree box.
      final center =
          (rects[kids.first]!.center.dx + rects[kids.last]!.center.dx) / 2;
      x = (center - ownWidth / 2).clamp(
        left,
        left + width - ownWidth,
      );
    }
    final rowTop =
        style.padding + depth * (style.nodeHeight + style.verticalGap);
    final height = isCompact(id) ? style.compactHeight : style.nodeHeight;
    // Compact markers sit on the same row, vertically centered so the
    // connector still flows parent -> marker -> child.
    final top = rowTop + (style.nodeHeight - height) / 2;
    final rect = Rect.fromLTWH(x, top, ownWidth, height);
    rects[id] = rect;
    depths[id] = depth;
    if (rect.bottom > maxBottom) maxBottom = rect.bottom;
  }

  var cursorX = style.padding;
  for (final root in layoutRoots) {
    position(root, cursorX, 0);
    cursorX += subtreeWidth(root) + style.rootGap;
  }

  // `placed` preserves insertion order, which `collect` builds as DFS
  // pre-order from the sorted roots — parents before their children.
  final placements = <GraphNodePlacement>[];
  for (final id in placed) {
    final node = byId[id]!;
    final rect = rects[id];
    if (rect == null) continue; // Defensive: never render an unpositioned card.
    final directKids = children[id] ?? const <Node>[];
    final collapsed =
        !searching && collapsedIds.contains(id) && directKids.isNotEmpty;
    placements.add(
      GraphNodePlacement(
        node: node,
        rect: rect,
        depth: depths[id] ?? 0,
        placementParentId: placementParent[id],
        childCount: directKids.length,
        hiddenDescendants: collapsed ? _descendantCount(id, children) : 0,
        collapsed: collapsed,
        compact: isCompact(id),
      ),
    );
  }

  final edges = <GraphEdge>[];
  for (final p in placements) {
    final parentRect = p.rect;
    final kidIds =
        (children[p.node.id] ?? const <Node>[])
            .where((k) => rects.containsKey(k.id))
            .toList()
          ..sort(
            (a, b) => rects[a.id]!.center.dx.compareTo(rects[b.id]!.center.dx),
          );
    final n = kidIds.length;
    // Fan the parent-side endpoints across the card's bottom edge so many
    // children do not leave from the exact same pixel. Compact markers are
    // narrow, so the step is clamped to zero rather than going negative.
    final step = n <= 1
        ? 0.0
        : math.max(
            0.0,
            math.min(18.0, (parentRect.width - 40) / (n - 1)),
          );
    final claimed = placementChildren[p.node.id] ?? const <String>[];
    for (var i = 0; i < n; i++) {
      final kid = kidIds[i];
      final kidRect = rects[kid.id]!;
      final startX = n <= 1
          ? parentRect.center.dx
          : parentRect.center.dx + (i - (n - 1) / 2) * step;
      edges.add(
        GraphEdge(
          parentId: p.node.id,
          childId: kid.id,
          start: Offset(startX, parentRect.bottom),
          end: Offset(kidRect.center.dx, kidRect.top),
          primary: claimed.contains(kid.id),
          faint: p.compact || isCompact(kid.id),
        ),
      );
    }
  }

  final width = cursorX - style.rootGap + style.padding;
  return NodeGraphLayout(
    size: Size(
      math.max(width, style.nodeWidth + style.padding * 2),
      maxBottom + style.padding,
    ),
    placements: placements,
    edges: edges,
  );
}

/// Number of descendants reachable from [id] in the full children map
/// (cycle-safe, counts each node once).
int _descendantCount(String id, Map<String, List<Node>> children) {
  final seen = <String>{id};
  final queue = <String>[id];
  var count = 0;
  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    for (final kid in children[current] ?? const <Node>[]) {
      if (seen.add(kid.id)) {
        count++;
        queue.add(kid.id);
      }
    }
  }
  return count;
}

int _compareGoals(Node a, Node b) {
  final aDue = a.schedule?.due;
  final bDue = b.schedule?.due;
  if (aDue == null && bDue == null) {
    final byCreated = a.createdAt.compareTo(b.createdAt);
    return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
  }
  if (aDue == null) return 1;
  if (bDue == null) return -1;
  final cmp = aDue.compareTo(bDue);
  return cmp != 0 ? cmp : a.id.compareTo(b.id);
}
