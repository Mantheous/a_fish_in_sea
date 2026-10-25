import 'package:flutter/material.dart';

import '../model/node.dart';
import '../service/node_graph_layout.dart';

/// One goal card on the graph canvas.
///
/// Tapping the card selects it; tapping the selected card opens the editor,
/// and the selection's action bar offers the same edit plus recording and
/// goal controls. The footer carries the quick tree actions: a −/+ badge
/// collapses or expands the subtree, and the two small arrows grow the tree
/// in place — `↓` creates a subgoal under this goal, `↑` creates a parent
/// goal above it. Generated instances get neither action: their structure is
/// owned by the template that produced them.
class NodeGraphCard extends StatelessWidget {
  const NodeGraphCard({
    super.key,
    required this.placement,
    required this.progress,
    required this.isMatch,
    required this.selected,
    required this.showToggle,
    required this.onTap,
    required this.onToggle,
    required this.onAddSubgoal,
    required this.onAddParent,
  });

  final GraphNodePlacement placement;
  final double progress;
  final bool isMatch;

  /// True while this card is the graph's selected goal.
  final bool selected;

  final bool showToggle;

  /// Card tap: select on the first tap, edit on the next.
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onAddSubgoal;
  final VoidCallback onAddParent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final node = placement.node;
    if (placement.compact) return _compactCard(context, node, selected);
    final isRoot = node.parentIds.isEmpty;
    final fill = _fill(theme, node);
    final border = selected || isMatch
        ? scheme.primary
        : isRoot
        ? scheme.primary.withValues(alpha: 0.55)
        : scheme.outlineVariant;
    final titleColor = node.status == NodeStatus.failed
        ? scheme.error
        : node.isDone
        ? scheme.outline
        : scheme.onSurface;
    // Generated instances are structural records, not editable tree
    // members: they cannot parent children and cannot take a second
    // parent, so neither add action is offered.
    final canGrow = node.instanceOfId == null;
    return Tooltip(
      message: _tooltip(node, selected),
      waitDuration: const Duration(milliseconds: 600),
      child: Material(
        color: fill,
        elevation: selected ? 6 : 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(isRoot ? 28 : 10),
          side: BorderSide(
            color: border,
            width: selected ? 3 : isMatch ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
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
                    if (canGrow) ...[
                      const SizedBox(width: 4),
                      _addButton(
                        context,
                        key: ValueKey('graph-add-subgoal-${node.id}'),
                        tooltip: 'Add subgoal',
                        icon: Icons.arrow_downward,
                        onTap: onAddSubgoal,
                      ),
                      const SizedBox(width: 2),
                      _addButton(
                        context,
                        key: ValueKey('graph-add-parent-${node.id}'),
                        tooltip: 'Add parent goal',
                        icon: Icons.arrow_upward,
                        onTap: onAddParent,
                      ),
                    ],
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
  Widget _compactCard(BuildContext context, Node node, bool selected) {
    final scheme = Theme.of(context).colorScheme;
    final title = node.title.isEmpty ? '(untitled)' : node.title;
    return Tooltip(
      message:
          '$title\nfiltered out · shown to keep the link\n'
          '${selected ? 'selected · tap again to edit' : 'tap to select'}',
      waitDuration: const Duration(milliseconds: 500),
      child: Opacity(
        opacity: 0.82,
        child: Material(
          color: selected
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
            side: BorderSide(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
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

  /// Small circular tree action (add subgoal / add parent goal). Sized like
  /// the collapse badge so the footer keeps one row on a fixed-size card.
  Widget _addButton(
    BuildContext context, {
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Container(
          width: 20,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            color: scheme.surface,
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Icon(icon, size: 12, color: scheme.onSurfaceVariant),
        ),
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

  String _tooltip(Node node, bool selected) {
    final parts = <String>[node.title.isEmpty ? '(untitled)' : node.title];
    parts.add(
      node.isUnbounded
          ? 'unbounded · ongoing'
          : '${(progress * 100).round()}% complete',
    );
    if (node.isDone) parts.add('done');
    if (node.status == NodeStatus.failed) parts.add('failed');
    if (node.isTracking) parts.add('recording');
    parts.add(selected ? 'selected · tap again to edit' : 'tap to select');
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
