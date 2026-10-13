import 'package:flutter/material.dart';

import 'demo_coordinator.dart';

/// Home-page tour card, demo only: points at one thing to try per
/// integration so a first-time visitor actually exercises them.
class DemoTourCard extends StatelessWidget {
  const DemoTourCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.map_outlined,
                    color: theme.colorScheme.onTertiaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Demo tour — everything here is mock',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => DemoCoordinator.exitDemo(context),
                  style: TextButton.styleFrom(
                    foregroundColor:
                        theme.colorScheme.onTertiaryContainer,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('Exit'),
                ),
              ],
            ),
            const _TourLine(
              icon: Icons.checklist_outlined,
              text: 'Tasks: tick off homework, then undo it.',
            ),
            const _TourLine(
              icon: Icons.sync_outlined,
              text:
                  'Refresh feeds (Tasks or Calendar): submitted Canvas work completes itself.',
            ),
            const _TourLine(
              icon: Icons.school_outlined,
              text:
                  'Settings → Classes: disconnect + reconnect mock Canvas and Google.',
            ),
            const _TourLine(
              icon: Icons.attach_money_outlined,
              text:
                  'Finances → Bank: sync transactions, assign one to the food budget.',
            ),
            const _TourLine(
              icon: Icons.inbox_outlined,
              text:
                  'Import inbox below: approve the staged email import. Tasks → syllabus import works too.',
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

class _TourLine extends StatelessWidget {
  final IconData icon;
  final String text;

  const _TourLine({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon,
              size: 16, color: theme.colorScheme.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
