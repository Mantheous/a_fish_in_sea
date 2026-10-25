import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Wide screens put the goal editor on the right edge as a full-height
/// sheet, matching the calendar's task panel; narrower screens keep the
/// centered dialog. 840 is Material's "expanded" window class, the first
/// width where a 360px+ panel leaves the page behind it usable.
const double nodeEditorSideSheetBreakpoint = 840;

/// Key on the wide-screen side sheet, so tests can tell the side panel
/// presentation apart from the centered dialog.
const Key nodeEditorSideSheetKey = Key('node-editor-side-sheet');

/// Presentation shell for the goal editor on wide screens: a full-height,
/// right-aligned panel with a title/close header, a scrolling form body,
/// and a pinned action footer.
class NodeEditorSideSheet extends StatelessWidget {
  const NodeEditorSideSheet({
    super.key,
    required this.title,
    required this.form,
    required this.actions,
  });

  final Widget title;
  final Widget form;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context).width;
    final width = math.min(440.0, math.max(320.0, screen * 0.46));
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        key: nodeEditorSideSheetKey,
        width: width,
        height: double.infinity,
        child: Material(
          color: theme.colorScheme.surface,
          elevation: 16,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: DefaultTextStyle.merge(
                          style: theme.textTheme.titleLarge,
                          child: title,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                    child: form,
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: actions,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
