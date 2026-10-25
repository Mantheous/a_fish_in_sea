import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/node.dart';
import '../service/node_graph_layout.dart';
import 'node_editor.dart';

/// Graphical top-down view of the goal DAG, following the board in
/// `docs/goal-tree-issue-4.png`: layered cards joined by curved connectors.
///
/// An alternative to the list views, not a replacement: tap a card to edit
/// (same editor as everywhere else) and tap the −/+ badge under a card to
/// collapse or expand that subtree. Pan and zoom to move around large
/// trees. Repeating templates and goals with a very wide fan-out start
/// collapsed so their generated instances or subgoal walls don't flood the
/// graph.
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
  bool _seededDefaults = false;

  @override
  void didUpdateWidget(covariant NodeGraphView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expandToken != oldWidget.expandToken) {
      final withKids = _parentIds(widget.nodes);
      _collapsed
        ..clear()
        ..addAll(widget.expandAll ? const <String>[] : withKids);
    }
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
    if (!_seededDefaults && widget.nodes.isNotEmpty) {
      // One-time seed: habits/budgets generate an instance per period, so
      // drawing every instance by default would bury the actual tree. Goals
      // with more than [_autoCollapseSubgoals] direct subgoals start folded
      // for the same reason: the first screen shows the shape of the tree,
      // not one goal's whole fan-out. Expanding one by hand sticks.
      _seededDefaults = true;
      _collapsed.addAll(
        widget.nodes.where((n) => n.isTemplate).map((n) => n.id),
      );
      _collapsed.addAll(_wideParents(widget.nodes));
    }
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
    final canvas = _GraphCanvas(
      layout: layout,
      progress: widget.progress,
      matches: widget.matchedIds,
      showToggles: !restricted,
      onEdit: (node) => showNodeEditor(context, existing: node),
      onToggle: (id) => setState(() {
        if (!_collapsed.remove(id)) _collapsed.add(id);
      }),
    );
    final shown = restricted
        ? widget.matchedIds.length
        : layout.placements.length;
    return Stack(
      children: [
        Positioned.fill(
          child: _GraphViewport(
            layoutSize: layout.size,
            fitToken: widget.fitToken,
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
        Positioned(
          left: 12,
          bottom: 10,
          child: _GraphPill(
            text: widget.filterActive
                ? 'Filtered-out goals collapse · links stay visible'
                : 'Tap to edit · − / + collapses',
          ),
        ),
      ],
    );
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
  });

  final Size layoutSize;
  final Widget child;
  final int fitToken;

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

  @override
  void didUpdateWidget(covariant _GraphViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fitToken != oldWidget.fitToken) {
      _didFit = false;
      _scheduleFit();
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
    required this.showToggles,
    required this.onEdit,
    required this.onToggle,
  });

  final NodeGraphLayout layout;
  final Map<String, double> progress;
  final Set<String> matches;
  final bool showToggles;
  final ValueChanged<Node> onEdit;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
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
              child: _GraphNodeCard(
                key: ValueKey(
                  'graph-${placement.compact ? 'context' : 'node'}-'
                  '${placement.node.id}',
                ),
                placement: placement,
                progress: progress[placement.node.id] ?? 0,
                isMatch: matches.contains(placement.node.id),
                showToggle: showToggles,
                onEdit: () => onEdit(placement.node),
                onToggle: () => onToggle(placement.node.id),
              ),
            ),
        ],
      ),
    );
  }
}

class _GraphNodeCard extends StatelessWidget {
  const _GraphNodeCard({
    super.key,
    required this.placement,
    required this.progress,
    required this.isMatch,
    required this.showToggle,
    required this.onEdit,
    required this.onToggle,
  });

  final GraphNodePlacement placement;
  final double progress;
  final bool isMatch;
  final bool showToggle;
  final VoidCallback onEdit;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final node = placement.node;
    if (placement.compact) return _compactCard(context, node);
    final isRoot = node.parentIds.isEmpty;
    final fill = _fill(theme, node);
    final border = isMatch
        ? scheme.primary
        : isRoot
        ? scheme.primary.withValues(alpha: 0.55)
        : scheme.outlineVariant;
    final titleColor = node.status == NodeStatus.failed
        ? scheme.error
        : node.isDone
        ? scheme.outline
        : scheme.onSurface;
    return Tooltip(
      message: _tooltip(node),
      waitDuration: const Duration(milliseconds: 600),
      child: Material(
        color: fill,
        elevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(isRoot ? 28 : 10),
          side: BorderSide(color: border, width: isMatch ? 2 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onEdit,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(9, 6, 9, 5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Center(
                    child: Text(
                      node.title.isEmpty ? '(untitled)' : node.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.2,
                        color: titleColor,
                        decoration:
                            node.isDone || node.status == NodeStatus.failed
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(child: _footer(context, node)),
                    if (showToggle && placement.hasChildren) ...[
                      const SizedBox(width: 4),
                      _toggle(context),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A filtered-out ancestor, collapsed to a small path marker. It keeps
  /// the connector visible and stays tappable, but reads as context rather
  /// than as a matching goal.
  Widget _compactCard(BuildContext context, Node node) {
    final scheme = Theme.of(context).colorScheme;
    final title = node.title.isEmpty ? '(untitled)' : node.title;
    return Tooltip(
      message: '$title\nfiltered out · shown to keep the link',
      waitDuration: const Duration(milliseconds: 500),
      child: Opacity(
        opacity: 0.82,
        child: Material(
          color: scheme.surfaceContainerHighest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
            side: BorderSide(color: scheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onEdit,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.filter_alt_off_outlined,
                    size: 10,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 9,
                        height: 1.1,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Progress strip (or the ongoing marker for unbounded goals).
  Widget _footer(BuildContext context, Node node) {
    final scheme = Theme.of(context).colorScheme;
    if (node.isUnbounded) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Icon(
          Icons.all_inclusive,
          size: 12,
          color: scheme.onSurfaceVariant,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        value: progress.clamp(0.0, 1.0),
        minHeight: 3,
        backgroundColor: scheme.surfaceContainerHighest,
      ),
    );
  }

  /// Collapse/expand badge: a minus while expanded, the hidden count while
  /// collapsed — the standard mind-map affordance.
  Widget _toggle(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final collapsed = placement.collapsed;
    return Tooltip(
      message: collapsed
          ? 'Expand ${placement.hiddenDescendants} hidden goal'
                '${placement.hiddenDescendants == 1 ? '' : 's'}'
          : 'Collapse ${placement.childCount} direct '
                'subgoal${placement.childCount == 1 ? '' : 's'}',
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        key: ValueKey('graph-toggle-${placement.node.id}'),
        borderRadius: BorderRadius.circular(9),
        onTap: onToggle,
        child: Container(
          width: 24,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.surface,
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: collapsed
              ? FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Text(
                      '+${placement.hiddenDescendants}',
                      style: TextStyle(
                        fontSize: 8,
                        height: 1,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                )
              : Icon(Icons.remove, size: 12, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }

  String _tooltip(Node node) {
    final parts = <String>[node.title.isEmpty ? '(untitled)' : node.title];
    parts.add(
      node.isUnbounded
          ? 'unbounded · ongoing'
          : '${(progress * 100).round()}% complete',
    );
    if (node.isDone) parts.add('done');
    if (node.status == NodeStatus.failed) parts.add('failed');
    if (node.isTracking) parts.add('recording');
    parts.add('tap to edit');
    return parts.join('\n');
  }

  /// Card fill reads the goal's state at a glance: green for done, teal
  /// while recording, error tint for failed, secondary for unbounded and
  /// repeating templates — the colored boxes on the Figma board.
  static Color _fill(ThemeData theme, Node node) {
    final scheme = theme.colorScheme;
    final surface = scheme.surfaceContainerHigh;
    if (node.status == NodeStatus.failed) return scheme.errorContainer;
    if (node.isDone) {
      final green = theme.brightness == Brightness.dark
          ? const Color(0xFF3E6B49)
          : const Color(0xFF9ED8A9);
      return Color.alphaBlend(green.withValues(alpha: 0.55), surface);
    }
    if (node.isTracking) {
      return Color.alphaBlend(scheme.primary.withValues(alpha: 0.2), surface);
    }
    if (node.isUnbounded) {
      return Color.alphaBlend(
        scheme.secondary.withValues(alpha: 0.16),
        surface,
      );
    }
    if (node.isTemplate) {
      return Color.alphaBlend(scheme.tertiary.withValues(alpha: 0.14), surface);
    }
    return surface;
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
