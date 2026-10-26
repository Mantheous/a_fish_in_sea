import 'package:flutter/material.dart';

/// Date pick/clear row used by the node editor (due date, recurrence end).
/// Extracted from `node_editor.dart` without behavior change.
class NodeEditorDateRow extends StatelessWidget {
  final String label;
  final VoidCallback onPick;
  final VoidCallback? onClear;

  const NodeEditorDateRow({
    super.key,
    required this.label,
    required this.onPick,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(
          tooltip: 'Pick date',
          icon: const Icon(Icons.event),
          onPressed: onPick,
        ),
        if (onClear != null)
          IconButton(
            tooltip: 'Clear date',
            icon: const Icon(Icons.event_busy),
            onPressed: onClear,
          ),
      ],
    );
  }
}
