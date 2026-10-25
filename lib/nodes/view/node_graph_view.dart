import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../planner/bloc/calendar_cubit.dart';
import '../bloc/node_cubit.dart';
import '../model/node.dart';
import '../service/node_event_link.dart';
import '../service/node_graph_layout.dart';
import 'node_editor.dart';
import 'node_finish_sheet.dart';
import 'node_graph_action_bar.dart';
import 'node_graph_card.dart';

/// Graphical top-down view of the goal DAG, following the board in
/// `docs/goal-tree-issue-4.png`: layered cards joined by curved connectors.
///
/// An alternative to the list views, not a replacement: tap a card to select
/// it, tap it again to edit (same editor as everywhere else). A selected
/// card floats an action bar with the goal's quick controls — record time
/// toward it, edit, add a subgoal or parent, mark it complete — while the
/// −/+ badge under a card collapses or expands that subtree. Each card also
/// grows the tree in place: its `↓` button creates a subgoal beneath it and
/// its `↑` button creates a parent goal above it. Pan and zoom to move around
/// large trees. Repeating templates and goals with a very wide fan-out start
/// collapsed so their generated instances or subgoal walls don't flood the
/// graph. Folding is reported through [onCollapsedChanged] and can be
/// restored with [collapsedIds], so leaving the Goals tab and coming back
/// shows the same graph.
class NodeGraphView extends StatefulWidget {
  const NodeGraphView({
    super.key,
    required this.nodes,
    required this.progress,
    this.visibleIds,
    this.contextIds = const <String>{},
    this.matchedIds = const <String>{},
    this.filterActive = false,
    this.filterSummary,
    this.fitToken = 0,
    this.expandAll = false,
    this.expandToken = 0,
    this.collapsedIds,
    this.onCollapsedChanged,
    this.onClearFilters,
  });

  /// Goal-tree nodes (see [goalNodes]).
  final List<Node> nodes;

  /// Progress per node id, from `progressForest`.
  final Map<String, double> progress;

  /// Restriction from search/filter; null = show everything. When set, the
  /// graph ignores manual collapse so matches are always reachable.
  final Set<String>? visibleIds;

  /// Filtered-out ancestors of the matches. These render as compact path
  /// markers instead of full cards, preserving "this connects to this".
  final Set<String> contextIds;

  /// Goals that passed the active filter/search; these get the match
  /// outline and a full card.
  final Set<String> matchedIds;

  /// True when [contextIds] came from the filter menu (not plain search).
  final bool filterActive;

  /// Human summary of the active filter, shown in the stats pill.
  final String? filterSummary;

  /// Bumped when the filter changes so the viewport re-fits the new graph
  /// instead of keeping the previous pan/zoom.
  final int fitToken;

  /// Mirrors the page-level expand/collapse-all button. [expandToken] bumps
  /// on every tap; [expandAll] is the new state.
  final bool expandAll;
  final int expandToken;

  /// Folded subtree ids carried across page visits. Null means "seed the
  /// defaults": repeating templates and goals with more than five direct
  /// subgoals start collapsed. A non-null set is the user's own fold state
  /// and is used as-is, so a manual expand survives a tab switch.
  final Set<String>? collapsedIds;

  /// Reports the folded set whenever it changes (default seed, a toggle, or
  /// the page-level expand/collapse-all), so the owner can keep it.
  final ValueChanged<Set<String>>? onCollapsedChanged;

  /// Clears the active filter from the graph's empty state.
  final VoidCallback? onClearFilters;

  @override
  State<NodeGraphView> createState() => _NodeGraphViewState();
}

class _NodeGraphViewState extends State<NodeGraphView> {
  /// A goal with more direct subgoals than this starts collapsed, so one
  /// wide parent cannot fill the first screen with its children.
  static const int _autoCollapseSubgoals = 5;

  final Set<String> _collapsed = <String>{};
  bool _seeded = false;

  /// The goal whose action bar is showing. Selection is transient view state
  /// (never persisted): it clears on a background tap, the bar's ✕, a
  /// collapse that hides the card, and a tab switch.
  String? _selectedId;

  /// Most recently added goal. The viewport pans just enough to show it
  /// without changing zoom, so growing the tree is visible even when the
  /// new card lands outside the current view (e.g. a new parent root to
  /// the right of the tree).
  String? _revealId;
  int _revealToken = 0;

  @override
  void didUpdateWidget(covariant NodeGraphView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Deleting or filtering out the selected goal leaves no card to act on;
    // never keep an invisible selection pointing at a missing node.
    if (_selectedId != null &&
        !widget.nodes.any((node) => node.id == _selectedId)) {
      _selectedId = null;
    }
    if (widget.expandToken != oldWidget.expandToken) {
      final withKids = _parentIds(widget.nodes);
      _seeded = true;
      _collapsed
        ..clear()
        ..addAll(widget.expandAll ? const <String>[] : withKids);
      // Collapse-all folds the selected card out of view.
      if (!widget.expandAll) _selectedId = null;
      _reportCollapsed();
    }
  }

  /// One-time seed, once goals exist. A set carried in
  /// [NodeGraphView.collapsedIds] wins: that is the fold state from an
  /// earlier visit to the page. Otherwise habits/budgets generate an
  /// instance per period and goals with more than [_autoCollapseSubgoals]
  /// direct subgoals flood the canvas, so both start folded — the first
  /// screen shows the shape of the tree, not one goal's whole fan-out.
  void _seedIfNeeded() {
    if (_seeded || widget.nodes.isEmpty) return;
    _seeded = true;
    final saved = widget.collapsedIds;
    _collapsed.addAll(saved ?? _defaultCollapsed(widget.nodes));
    if (saved == null) _reportCollapsed();
  }

  static Set<String> _defaultCollapsed(List<Node> nodes) => {
    for (final n in nodes)
      if (n.isTemplate) n.id,
    ..._wideParents(nodes),
  };

  /// Hands the current folded set to the owner. Deferred to after the frame:
  /// the seed runs during build and the expand-all path runs inside
  /// [didUpdateWidget], so the owner must not rebuild mid-frame.
  void _reportCollapsed() {
    final notify = widget.onCollapsedChanged;
    if (notify == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) notify(Set<String>.unmodifiable(_collapsed));
    });
  }

  /// Parent ids that have at least one child in [nodes].
  static Set<String> _parentIds(List<Node> nodes) {
    final ids = {for (final n in nodes) n.id};
    final out = <String>{};
    for (final n in nodes) {
      for (final p in n.parentIds) {
        if (ids.contains(p)) out.add(p);
      }
    }
    return out;
  }

  /// Parent ids whose direct subgoal count exceeds [_autoCollapseSubgoals].
  /// Only goals present in [nodes] count, so the seed matches what the graph
  /// can actually draw.
  static Set<String> _wideParents(List<Node> nodes) {
    final ids = {for (final n in nodes) n.id};
    final counts = <String, int>{};
    for (final n in nodes) {
      for (final p in n.parentIds) {
        if (ids.contains(p)) counts[p] = (counts[p] ?? 0) + 1;
      }
    }
    return {
      for (final entry in counts.entries)
        if (entry.value > _autoCollapseSubgoals) entry.key,
    };
  }

  @override
  Widget build(BuildContext context) {
    _seedIfNeeded();
    final restricted = widget.visibleIds != null;
    final layout = layoutNodeGraph(
      nodes: widget.nodes,
      collapsedIds: restricted ? const <String>{} : _collapsed,
      visibleIds: widget.visibleIds,
      compactIds: widget.contextIds,
    );
    if (layout.isEmpty) {
      return _EmptyGraph(
        filtering: widget.filterActive,
        restricting: restricted,
        onClearFilters: widget.onClearFilters,
      );
    }
    // The selection is only actionable while its card is on screen: a
    // collapse or a filter that hides it also hides the bar.
    GraphNodePlacement? selectedPlacement;
    if (_selectedId != null) {
      for (final placement in layout.placements) {
        if (placement.node.id == _selectedId) {
          selectedPlacement = placement;
          break;
        }
      }
    }
    final selectedNode = selectedPlacement?.node;
    final canvas = _GraphCanvas(
      layout: layout,
      progress: widget.progress,
      matches: widget.matchedIds,
      selectedId: selectedNode?.id,
      showToggles: !restricted,
      onCardTap: _selectOrEdit,
      onBackgroundTap: _clearSelection,
      onToggle: _toggleCollapsed,
      onAddSubgoal: _addSubgoal,
      onAddParent: _addParent,
    );
    final shown = restricted
        ? widget.matchedIds.length
        : layout.placements.length;
    GraphNodePlacement? reveal;
    if (_revealId != null) {
      for (final placement in layout.placements) {
        if (placement.node.id == _revealId) {
          reveal = placement;
          break;
        }
      }
    }
    return Stack(
      children: [
        Positioned.fill(
          child: _GraphViewport(
            layoutSize: layout.size,
            fitToken: widget.fitToken,
            revealRect: reveal?.rect,
            revealToken: _revealToken,
            child: canvas,
          ),
        ),
        Positioned(
          left: 12,
          top: 10,
          child: _GraphPill(
            text: widget.filterActive
                ? '$shown of ${widget.nodes.length} goals · '
                      '${widget.filterSummary ?? 'filtered'}'
                : '$shown of ${widget.nodes.length} goals',
          ),
        ),
        if (selectedNode != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: NodeGraphActionBar(
                key: nodeGraphActionBarKey,
                node: selectedNode,
                onRecord: () => _toggleRecording(selectedNode),
                onEdit: () => showNodeEditor(context, existing: selectedNode),
                onAddSubgoal: selectedNode.instanceOfId == null
                    ? () => _addSubgoal(selectedNode)
                    : null,
                onAddParent: selectedNode.instanceOfId == null
                    ? () => _addParent(selectedNode)
                    : null,
                onToggleDone: selectedNode.isUnbounded
                    ? null
                    : () => _toggleDone(selectedNode),
                onClose: _clearSelection,
              ),
            ),
          )
        else
          Positioned(
            left: 12,
            bottom: 10,
            child: _GraphPill(
              text: widget.filterActive
                  ? 'Filtered-out goals collapse · links stay visible'
                  : 'Tap to select · tap again to edit · −/+ collapses',
            ),
          ),
      ],
    );
  }

  /// Card tap: the first tap selects the goal and opens its action bar; a
  /// tap on the already-selected card opens the editor, the same as before.
  void _selectOrEdit(Node node) {
    if (_selectedId == node.id) {
      showNodeEditor(context, existing: node);
      return;
    }
    setState(() => _selectedId = node.id);
  }

  void _clearSelection() {
    if (_selectedId == null) return;
    setState(() => _selectedId = null);
  }

  /// Folds or unfolds [id] and drops a selection that the fold hides.
  void _toggleCollapsed(String id) {
    final collapsing = !_collapsed.contains(id);
    final selection = _selectedId;
    setState(() {
      if (!_collapsed.remove(id)) _collapsed.add(id);
      if (collapsing &&
          selection != null &&
          selection != id &&
          _hasAncestor(widget.nodes, selection, id)) {
        _selectedId = null;
      }
    });
    _reportCollapsed();
  }

  /// True when [ancestorId] is one of [nodeId]'s ancestors in [nodes].
  /// Walks every parent (the goal tree is a DAG, so a goal can sit under
  /// more than one parent).
  static bool _hasAncestor(List<Node> nodes, String nodeId, String ancestorId) {
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

  /// Starts the selected goal's timer, or stops it through the same finish
  /// flow the task rows use (which mirrors the run onto linked events).
  void _toggleRecording(Node node) {
    if (node.isTracking) {
      stopNodeAndFinish(context, node.id);
      return;
    }
    try {
      NodeEventLink.startNodeTracking(
        context.read<NodeCubit>(),
        context.read<CalendarCubit>(),
        node.id,
      );
    } catch (_) {}
  }

  /// Marks the selected goal complete, or reopens it when it is done.
  void _toggleDone(Node node) {
    try {
      NodeEventLink.toggleNodeDone(
        context.read<NodeCubit>(),
        context.read<CalendarCubit>(),
        node.id,
      );
    } catch (_) {
      try {
        context.read<NodeCubit>().toggleDone(node.id);
      } catch (_) {}
    }
  }

  /// "Add subgoal": the new goal is created with [parent] pre-selected as
  /// its parent. A collapsed parent is expanded on success so the new card
  /// is actually visible instead of hidden behind its own count badge.
  Future<void> _addSubgoal(Node parent) async {
    final created = await showNodeEditor(
      context,
      initialParentIds: [parent.id],
    );
    if (!mounted || created == null) return;
    setState(() {
      _collapsed.remove(parent.id);
      _revealId = created.id;
      _revealToken++;
    });
    _reportCollapsed();
  }

  /// "Add parent goal": the new goal is created as a parent of [child] in
  /// one write, so the edge exists the moment the card appears.
  Future<void> _addParent(Node child) async {
    final created = await showNodeEditor(context, initialChildIds: [child.id]);
    if (!mounted || created == null) return;
    setState(() {
      _revealId = created.id;
      _revealToken++;
    });
  }
}

class _EmptyGraph extends StatelessWidget {
  const _EmptyGraph({
    required this.filtering,
    required this.restricting,
    this.onClearFilters,
  });

  final bool filtering;
  final bool restricting;
  final VoidCallback? onClearFilters;

  @override
  Widget build(BuildContext context) {
    final message = filtering
        ? 'No goals match these filters.'
        : restricting
        ? 'No goals match the search.'
        : 'No goals yet.';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message),
          if (filtering && onClearFilters != null) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: onClearFilters,
              child: const Text('Clear filters'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Pan/zoom surface with floating zoom controls. Fits the whole layout to
/// the viewport once; afterwards the transform is the user's.
class _GraphViewport extends StatefulWidget {
  const _GraphViewport({
    required this.layoutSize,
    required this.child,
    this.fitToken = 0,
    this.revealRect,
    this.revealToken = 0,
  });

  final Size layoutSize;
  final Widget child;
  final int fitToken;

  /// Canvas-space rect to bring into view when [revealToken] changes.
  final Rect? revealRect;
  final int revealToken;

  @override
  State<_GraphViewport> createState() => _GraphViewportState();
}

class _GraphViewportState extends State<_GraphViewport> {
  static const double _minScale = 0.12;
  static const double _maxScale = 2.5;

  final TransformationController _controller = TransformationController();
  Size _viewport = Size.zero;
  bool _didFit = false;
  bool _fitScheduled = false;
  bool _revealScheduled = false;

  @override
  void didUpdateWidget(covariant _GraphViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fitToken != oldWidget.fitToken) {
      _didFit = false;
      _scheduleFit();
    } else if (widget.revealToken != oldWidget.revealToken) {
      _scheduleReveal();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scheduleFit() {
    if (_fitScheduled) return;
    _fitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fitScheduled = false;
      if (!mounted) return;
      _didFit = true;
      _fit();
    });
  }

  /// Pans minimally so [widget.revealRect] is inside the viewport, keeping
  /// the user's zoom. A card already in view does not move the canvas.
  void _scheduleReveal() {
    if (_revealScheduled) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted) return;
      _reveal();
    });
  }

  void _reveal() {
    final rect = widget.revealRect;
    if (rect == null || _viewport.isEmpty) return;
    final m = _controller.value;
    final scale = m.getMaxScaleOnAxis();
    final t = m.getTranslation();
    const padding = 24.0;
    final left = rect.left * scale + t.x;
    final top = rect.top * scale + t.y;
    final right = rect.right * scale + t.x;
    final bottom = rect.bottom * scale + t.y;
    var dx = 0.0;
    var dy = 0.0;
    if (right > _viewport.width - padding) {
      dx = _viewport.width - padding - right;
    }
    if (left + dx < padding) dx = padding - left;
    if (bottom > _viewport.height - padding) {
      dy = _viewport.height - padding - bottom;
    }
    if (top + dy < padding) dy = padding - top;
    if (dx == 0 && dy == 0) return;
    _controller.value = _matrix(scale, t.x + dx, t.y + dy);
  }

  Matrix4 _matrix(double scale, double tx, double ty) {
    final m = Matrix4.identity();
    m.setEntry(0, 0, scale);
    m.setEntry(1, 1, scale);
    m.setEntry(2, 2, scale);
    m.setEntry(0, 3, tx);
    m.setEntry(1, 3, ty);
    return m;
  }

  void _fit() {
    if (_viewport.isEmpty || widget.layoutSize.isEmpty) return;
    final scale = math
        .min(1.0, (_viewport.width - 48) / widget.layoutSize.width)
        .clamp(_minScale, _maxScale);
    final tx = (_viewport.width - widget.layoutSize.width * scale) / 2;
    final scaledHeight = widget.layoutSize.height * scale;
    final ty = scaledHeight < _viewport.height
        ? math.max(16.0, (_viewport.height - scaledHeight) / 2)
        : 16.0;
    _controller.value = _matrix(scale, tx, ty);
  }

  void _zoomBy(double factor) {
    if (_viewport.isEmpty) return;
    final m = _controller.value;
    final scale = m.getMaxScaleOnAxis();
    final next = (scale * factor).clamp(_minScale, _maxScale);
    if (next == scale) return;
    final f = next / scale;
    final center = Offset(_viewport.width / 2, _viewport.height / 2);
    final t = m.getTranslation();
    final tx = center.dx - f * (center.dx - t.x);
    final ty = center.dy - f * (center.dy - t.y);
    _controller.value = _matrix(next, tx, ty);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = Size(constraints.maxWidth, constraints.maxHeight);
        if (!_didFit && !_fitScheduled) {
          _scheduleFit();
        }
        return Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: _controller,
                constrained: false,
                boundaryMargin: const EdgeInsets.all(600),
                minScale: _minScale,
                maxScale: _maxScale,
                child: SizedBox(
                  width: widget.layoutSize.width,
                  height: widget.layoutSize.height,
                  child: widget.child,
                ),
              ),
            ),
            Positioned(
              right: 12,
              top: 10,
              child: Material(
                elevation: 1,
                borderRadius: BorderRadius.circular(24),
                color: scheme.surfaceContainerHigh.withValues(alpha: 0.94),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Zoom out',
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      onPressed: () => _zoomBy(0.8),
                      icon: const Icon(Icons.remove),
                    ),
                    IconButton(
                      tooltip: 'Zoom in',
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      onPressed: () => _zoomBy(1.25),
                      icon: const Icon(Icons.add),
                    ),
                    IconButton(
                      tooltip: 'Fit to screen',
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      onPressed: _fit,
                      icon: const Icon(Icons.fit_screen_outlined),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _GraphPill extends StatelessWidget {
  const _GraphPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text, style: Theme.of(context).textTheme.labelSmall),
      ),
    );
  }
}

/// Edges first, cards on top.
class _GraphCanvas extends StatelessWidget {
  const _GraphCanvas({
    required this.layout,
    required this.progress,
    required this.matches,
    required this.selectedId,
    required this.showToggles,
    required this.onCardTap,
    required this.onBackgroundTap,
    required this.onToggle,
    required this.onAddSubgoal,
    required this.onAddParent,
  });

  final NodeGraphLayout layout;
  final Map<String, double> progress;
  final Set<String> matches;

  /// The goal whose card paints the selection ring, if any.
  final String? selectedId;

  final bool showToggles;
  final ValueChanged<Node> onCardTap;

  /// A tap on empty canvas clears the selection.
  final VoidCallback onBackgroundTap;

  final ValueChanged<String> onToggle;
  final ValueChanged<Node> onAddSubgoal;
  final ValueChanged<Node> onAddParent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onBackgroundTap,
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: _GraphEdgePainter(
                edges: layout.edges,
                color: scheme.outline,
              ),
            ),
          ),
          for (final placement in layout.placements)
            Positioned(
              left: placement.rect.left,
              top: placement.rect.top,
              width: placement.rect.width,
              height: placement.rect.height,
              child: NodeGraphCard(
                key: ValueKey(
                  'graph-${placement.compact ? 'context' : 'node'}-'
                  '${placement.node.id}',
                ),
                placement: placement,
                progress: progress[placement.node.id] ?? 0,
                isMatch: matches.contains(placement.node.id),
                selected: placement.node.id == selectedId,
                showToggle: showToggles,
                onTap: () => onCardTap(placement.node),
                onToggle: () => onToggle(placement.node.id),
                onAddSubgoal: () => onAddSubgoal(placement.node),
                onAddParent: () => onAddParent(placement.node),
              ),
            ),
        ],
      ),
    );
  }
}

class _GraphEdgePainter extends CustomPainter {
  const _GraphEdgePainter({required this.edges, required this.color});

  final List<GraphEdge> edges;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final primary = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final shared = Paint()
      ..color = color.withValues(alpha: 0.32)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final faint = Paint()
      ..color = color.withValues(alpha: 0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    for (final edge in edges) {
      final dy = edge.end.dy - edge.start.dy;
      final path = Path()
        ..moveTo(edge.start.dx, edge.start.dy)
        ..cubicTo(
          edge.start.dx,
          edge.start.dy + dy * 0.5,
          edge.end.dx,
          edge.end.dy - dy * 0.5,
          edge.end.dx,
          edge.end.dy,
        );
      canvas.drawPath(
        path,
        edge.faint ? faint : (edge.primary ? primary : shared),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GraphEdgePainter oldDelegate) =>
      oldDelegate.edges != edges || oldDelegate.color != color;
}
