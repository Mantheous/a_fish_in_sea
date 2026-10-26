import 'package:flutter/material.dart';

import '../model/node.dart';
import '../service/node_graph_layout.dart';
import 'node_graph_card.dart';

/// Edges first, cards on top. Selection is a set so multi-select can ring
/// every selected card at once.
class NodeGraphCanvas extends StatelessWidget {
  const NodeGraphCanvas({
    super.key,
    required this.layout,
    required this.progress,
    required this.matches,
    required this.selectedIds,
    required this.showToggles,
    required this.onCardTap,
    required this.onCardLongPress,
    required this.onBackgroundTap,
    required this.onToggle,
    required this.onAddSubgoal,
    required this.onAddParent,
  });

  final NodeGraphLayout layout;
  final Map<String, double> progress;
  final Set<String> matches;

  /// Goals whose cards paint the selection ring.
  final Set<String> selectedIds;

  final bool showToggles;
  final ValueChanged<Node> onCardTap;
  final ValueChanged<Node> onCardLongPress;

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
                selected: selectedIds.contains(placement.node.id),
                showToggle: showToggles,
                onTap: () => onCardTap(placement.node),
                onLongPress: () => onCardLongPress(placement.node),
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
