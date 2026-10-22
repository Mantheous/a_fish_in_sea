import 'package:flutter/material.dart';

/// Tinted row plus a colored edge for a highlighted task.
///
/// Extracted from the Tasks page tile so the tint styling lives in one
/// place while views gain custom colors: [hot] (due today) always glows
/// orange; otherwise [colorValue] tints the row, or the theme tertiary
/// when null (the legacy week look). The transparent Material keeps ink
/// splashes above the tint while the container paints the background and
/// the edge. [semanticsLabel] surfaces the same cue to screen readers.
class TaskHighlightTint extends StatelessWidget {
  final Widget child;
  final bool hot;
  final int? colorValue;
  final String semanticsLabel;

  const TaskHighlightTint({
    super.key,
    required this.child,
    required this.hot,
    this.colorValue,
    this.semanticsLabel = 'Highlighted',
  });

  @override
  Widget build(BuildContext context) {
    if (hot) {
      return Semantics(
        container: true,
        label: 'Due today',
        child: Container(
          decoration: BoxDecoration(
            color: Colors.orange.withAlpha(41),
            border: const Border(
              left: BorderSide(color: Colors.orange, width: 4),
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: child,
          ),
        ),
      );
    }
    final theme = Theme.of(context);
    final edge = colorValue == null
        ? theme.colorScheme.tertiary
        : Color(colorValue!);
    final background = colorValue == null
        ? theme.colorScheme.tertiaryContainer
        : Color(colorValue!).withAlpha(41);
    return Semantics(
      container: true,
      label: semanticsLabel,
      child: Container(
        decoration: BoxDecoration(
          color: background,
          border: Border(
            left: BorderSide(color: edge, width: 4),
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: child,
        ),
      ),
    );
  }
}
