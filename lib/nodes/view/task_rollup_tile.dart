import 'package:flutter/material.dart';

/// One collapsed row standing in for a group of plain task leaves.
///
/// The goal tree is about goals, but tasks still belong in it. Rendering
/// every open task as its own row buried the goals under hundreds of
/// rows, so plain scheduled leaves collapse into this summary and expand
/// on demand. [children] are already-built tiles; constructing them is
/// cheap and they only mount when the row expands.
class TaskRollupTile extends StatefulWidget {
  final List<Widget> children;
  final int openCount;
  final int doneCount;
  final EdgeInsetsGeometry tilePadding;
  final bool initiallyExpanded;
  final int expandToken;

  const TaskRollupTile({
    super.key,
    required this.children,
    required this.openCount,
    required this.doneCount,
    required this.tilePadding,
    this.initiallyExpanded = false,
    this.expandToken = 0,
  });

  @override
  State<TaskRollupTile> createState() => _TaskRollupTileState();
}

class _TaskRollupTileState extends State<TaskRollupTile> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  void didUpdateWidget(covariant TaskRollupTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expandToken != widget.expandToken ||
        oldWidget.initiallyExpanded != widget.initiallyExpanded) {
      _expanded = widget.initiallyExpanded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.openCount + widget.doneCount;
    final parts = <String>[];
    if (widget.openCount > 0) parts.add('${widget.openCount} open');
    if (widget.doneCount > 0) parts.add('${widget.doneCount} done');
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          contentPadding: widget.tilePadding,
          leading: const Icon(Icons.checklist_outlined),
          title: Text(total == 1 ? 'Task' : 'Tasks'),
          subtitle: Text(parts.join(' · ')),
          trailing: IconButton(
            tooltip: _expanded ? 'Collapse tasks' : 'Show tasks',
            icon: AnimatedRotation(
              turns: _expanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: const Icon(Icons.expand_more),
            ),
            onPressed: () => setState(() => _expanded = !_expanded),
          ),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded) ...widget.children,
      ],
    );
  }
}
