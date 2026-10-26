import 'package:flutter/material.dart';

/// Empty state for the goal graph, shared by the canvas and tests.
class GraphEmptyState extends StatelessWidget {
  const GraphEmptyState({
    super.key,
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

/// Small floating status/hint pill over the canvas.
class GraphPill extends StatelessWidget {
  const GraphPill({super.key, required this.text});

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
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    );
  }
}
