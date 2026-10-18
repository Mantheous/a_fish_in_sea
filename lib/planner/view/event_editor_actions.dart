import 'package:flutter/material.dart';

/// Actions stay in reach while the event fields scroll independently.
class EventEditorActions extends StatelessWidget {
  final String? title;
  final bool hasExistingEvent;
  final bool allowDelete;
  final bool saving;
  final VoidCallback? onDelete;
  final VoidCallback? onCancel;
  final VoidCallback? onSave;
  final String saveLabel;

  const EventEditorActions({
    super.key,
    this.title,
    required this.hasExistingEvent,
    required this.allowDelete,
    required this.saving,
    required this.onDelete,
    required this.onCancel,
    required this.onSave,
    required this.saveLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            Text(title!, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
          ],
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (hasExistingEvent && allowDelete)
                TextButton(
                  onPressed: saving ? null : onDelete,
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  child: const Text('Delete'),
                ),
              TextButton(
                onPressed: saving ? null : onCancel,
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: saving ? null : onSave,
                child: Text(saving ? 'Saving…' : saveLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
