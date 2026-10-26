import 'package:flutter/material.dart';

/// Floating zoom/tool pill, modeled on Figma's bottom-right controls: hand
/// tool, zoom out/in, a percentage menu with presets, and fit-to-screen.
class NodeGraphNavControls extends StatelessWidget {
  const NodeGraphNavControls({
    super.key,
    required this.zoomPercent,
    required this.handTool,
    required this.onToggleHand,
    required this.onZoomOut,
    required this.onZoomIn,
    required this.onZoomTo,
    required this.onFit,
  });

  final int zoomPercent;
  final bool handTool;
  final VoidCallback onToggleHand;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;
  final ValueChanged<double> onZoomTo;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 1,
      borderRadius: BorderRadius.circular(24),
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.94),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const ValueKey('graph-pan-tool'),
            tooltip: handTool ? 'Select tool (V)' : 'Pan tool (H)',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            style: IconButton.styleFrom(
              backgroundColor: handTool ? scheme.primaryContainer : null,
            ),
            onPressed: onToggleHand,
            icon: Icon(handTool ? Icons.back_hand : Icons.back_hand_outlined),
          ),
          IconButton(
            tooltip: 'Zoom out',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            onPressed: onZoomOut,
            icon: const Icon(Icons.remove),
          ),
          PopupMenuButton<double>(
            key: const ValueKey('graph-zoom-menu'),
            tooltip: 'Zoom',
            onSelected: (value) => value == 0 ? onFit() : onZoomTo(value),
            itemBuilder: (context) => [
              for (final percent in const [
                25.0,
                50.0,
                75.0,
                100.0,
                150.0,
                200.0,
              ])
                PopupMenuItem(
                  value: percent / 100,
                  child: Text('${percent.round()}%'),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 0, child: Text('Fit to screen')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                '$zoomPercent%',
                key: const ValueKey('graph-zoom-label'),
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Zoom in',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            onPressed: onZoomIn,
            icon: const Icon(Icons.add),
          ),
          IconButton(
            tooltip: 'Fit to screen',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            onPressed: onFit,
            icon: const Icon(Icons.fit_screen_outlined),
          ),
        ],
      ),
    );
  }
}
