import 'package:flutter/material.dart';

/// Key on the multi-select action bar, so tests can find the bulk controls
/// without depending on which goals are selected.
const Key nodeGraphMultiBarKey = Key('graph-multi-action-bar');

/// Contextual actions for a multi-goal selection on the graph canvas.
///
/// Bulk edit leads: it opens the [showNodeBulkEditor] panel with the title
/// field disabled and every other section opt-in. Marking done and deleting
/// run as one undoable write for the whole selection.
class NodeGraphMultiActionBar extends StatelessWidget {
  const NodeGraphMultiActionBar({
    super.key,
    required this.count,
    required this.allDone,
    required this.canToggleDone,
    required this.onEdit,
    required this.onToggleDone,
    required this.onDelete,
    required this.onClose,
  });

  final int count;

  /// True when every selected goal is already done (the action reopens).
  final bool allDone;

  /// False when a selected goal is unbounded and therefore never completes.
  final bool canToggleDone;

  final VoidCallback onEdit;
  final VoidCallback onToggleDone;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 480;
    return Material(
      key: nodeGraphMultiBarKey,
      elevation: 8,
      borderRadius: BorderRadius.circular(18),
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.select_all, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Text('$count selected', style: theme.textTheme.titleSmall),
            const SizedBox(width: 10),
            if (wide)
              FilledButton.icon(
                key: const ValueKey('graph-multi-edit'),
                onPressed: onEdit,
                icon: const Icon(Icons.tune, size: 18),
                label: Text('Edit $count'),
              )
            else
              IconButton.filled(
                key: const ValueKey('graph-multi-edit'),
                tooltip: 'Bulk edit $count goals',
                onPressed: onEdit,
                visualDensity: VisualDensity.compact,
                iconSize: 20,
                icon: const Icon(Icons.tune),
              ),
            _action(
              key: const ValueKey('graph-multi-done'),
              tooltip: canToggleDone
                  ? (allDone
                        ? 'Reopen selected goals'
                        : 'Mark selected goals complete')
                  : 'Unbounded goals never complete',
              icon: allDone ? Icons.undo : Icons.check_circle_outline,
              onPressed: canToggleDone ? onToggleDone : null,
            ),
            _action(
              key: const ValueKey('graph-multi-delete'),
              tooltip: 'Delete selected goals',
              icon: Icons.delete_outline,
              onPressed: onDelete,
            ),
            const SizedBox(width: 2),
            _action(
              key: const ValueKey('graph-multi-close'),
              tooltip: 'Clear selection',
              icon: Icons.close,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }

  Widget _action({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      iconSize: 20,
      icon: Icon(icon),
    );
  }
}
