import 'package:flutter/material.dart';

import 'demo_coordinator.dart';

/// Slim persistent banner shown above every page while demoing, so the
/// mock-data state is never mistaken for the real account.
class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            Icon(Icons.science_outlined,
                size: 18, color: scheme.onTertiaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Demo mode · mock data — nothing here is saved.',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onTertiaryContainer,
                    ),
              ),
            ),
            TextButton(
              onPressed: () => DemoCoordinator.exitDemo(context),
              style: TextButton.styleFrom(
                foregroundColor: scheme.onTertiaryContainer,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('Exit demo'),
            ),
          ],
        ),
      ),
    );
  }
}
