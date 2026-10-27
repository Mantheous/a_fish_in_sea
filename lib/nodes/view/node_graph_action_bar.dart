import 'package:flutter/material.dart';

import '../model/node.dart';

/// Key on the floating action bar, so tests and the view can find it
/// without depending on the goal currently selected.
const Key nodeGraphActionBarKey = Key('graph-action-bar');

/// Contextual actions for the goal selected on the graph canvas.
///
/// Tapping a card selects it (a second tap opens the editor); this bar then
/// floats over the canvas with the actions worth one tap from a goal map.
/// Recording leads because starting time on a goal is the action the map was
/// missing: the list views had a play button, but graph cards did not.
class NodeGraphActionBar extends StatelessWidget {
  const NodeGraphActionBar({
    super.key,
    required this.node,
    required this.onRecord,
    required this.onEdit,
    required this.onAddSubgoal,
    required this.onAddParent,
    required this.onToggleDone,
    required this.onClose,
  });

  /// The selected goal.
  final Node node;

  /// Starts recording, or stops the running timer (the bar picks the one
  /// matching [Node.isTracking]).
  final VoidCallback onRecord;

  final VoidCallback onEdit;

  /// Null for generated instances: their structure belongs to the template.
  final VoidCallback? onAddSubgoal;
  final VoidCallback? onAddParent;

  /// Null for unbounded goals, which are ongoing directions and never done.
  final VoidCallback? onToggleDone;

  /// Clears the selection.
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tracking = node.isTracking;
    // Done goals cannot start a new recording (same rule as the task rows);
    // failed goals can, and starting reopens them. A timer that is already
    // running can always be stopped.
    final canRecord = tracking || (!node.isDone && !node.isUnbounded);
    // On phones the title would squeeze the buttons off the bar; the card
    // itself already shows which goal is selected.
    final showTitle = MediaQuery.sizeOf(context).width >= 600;
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(18),
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showTitle) ...[
              Icon(
                tracking ? Icons.fiber_manual_record : Icons.flag_outlined,
                size: 18,
                color: tracking ? scheme.error : scheme.primary,
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  node.title.isEmpty ? '(untitled)' : node.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: 10),
            ],
            if (!node.isUnbounded)
              IconButton(
                key: ValueKey(
                  tracking ? 'graph-action-stop' : 'graph-action-record',
                ),
                tooltip: tracking
                    ? 'Stop recording'
                    : canRecord
                    ? 'Start recording'
                    : 'Done — reopen the goal to record',
                onPressed: canRecord ? onRecord : null,
                style: IconButton.styleFrom(
                  backgroundColor: tracking ? scheme.error : scheme.primary,
                  foregroundColor: tracking ? scheme.onError : scheme.onPrimary,
                  disabledBackgroundColor: scheme.surfaceContainerHighest,
                  disabledForegroundColor: scheme.onSurfaceVariant,
                  minimumSize: const Size(36, 36),
                  padding: EdgeInsets.zero,
                ),
                icon: Icon(tracking ? Icons.stop : Icons.play_arrow, size: 20),
              ),
            _action(
              key: const ValueKey('graph-action-edit'),
              tooltip: 'Edit goal',
              icon: Icons.edit_outlined,
              onPressed: onEdit,
            ),
            if (onAddSubgoal != null)
              _action(
                key: const ValueKey('graph-action-subgoal'),
                tooltip: 'Add subgoal',
                icon: Icons.arrow_downward,
                onPressed: onAddSubgoal,
              ),
            if (onAddParent != null)
              _action(
                key: const ValueKey('graph-action-parent'),
                tooltip: 'Add parent goal',
                icon: Icons.arrow_upward,
                onPressed: onAddParent,
              ),
            if (onToggleDone != null)
              _action(
                key: const ValueKey('graph-action-done'),
                tooltip: node.isDone ? 'Reopen goal' : 'Mark complete',
                icon: node.isDone
                    ? Icons.undo
                    : Icons.check_circle_outline,
                onPressed: onToggleDone,
              ),
            const SizedBox(width: 2),
            _action(
              key: const ValueKey('graph-action-close'),
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
