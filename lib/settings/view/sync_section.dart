import 'package:a_fish_in_sea/demo/demo_coordinator.dart';
import 'package:a_fish_in_sea/demo/demo_mode.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:a_fish_in_sea/sync/sync_meta_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Sync status + manual sync + sign-out.
///
/// Extracted from `settings_page.dart` (split-on-touch: that file is over
/// the 500-line budget) without behavior changes. The keep-or-remove
/// sign-out dialog lives here.
class SyncSection extends StatelessWidget {
  const SyncSection({super.key});

  @override
  Widget build(BuildContext context) {
    // Static flag (not a cubit watch): entry/exit always rebuilds the whole
    // shell from main.dart, and this keeps standalone widget tests working
    // without a DemoCubit in the tree.
    if (DemoMode.isActive) return const _DemoSyncSection();
    final engine = context.read<SyncEngine>();
    return ValueListenableBuilder<EngineStatus>(
      valueListenable: engine.status,
      builder: (context, status, _) {
        final syncing = status == EngineStatus.syncing;
        final last = engine.lastSyncAt;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: syncing
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_done_outlined),
              title: Text(syncing
                  ? 'Syncing…'
                  : last == null
                      ? 'Never synced'
                      : 'Last synced ${_formatAgo(last)}'),
              subtitle: engine.lastError == null
                  ? null
                  : Text(engine.lastError!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
              trailing: TextButton(
                onPressed: syncing
                    ? null
                    : () => context.read<SyncEngine>().syncNow(),
                child: const Text('Sync now'),
              ),
            ),
            ValueListenableBuilder<List<String>>(
              valueListenable: engine.protectedDeletions,
              builder: (context, guarded, _) {
                if (guarded.isEmpty) return const SizedBox.shrink();
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Sync held back deletions for: ${guarded.join(', ')}. '
                        'This device is missing items the cloud still has. '
                        'That usually means its local app storage was lost — '
                        'not that you deleted them.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () {
                          // Clear the bookkeeping so the next sync
                          // re-downloads the cloud copy onto this device.
                          context.read<SyncMetaCubit>().reset();
                          context.read<SyncEngine>().syncNow();
                        },
                        icon: const Icon(Icons.restore),
                        label: const Text('Restore missing items from cloud'),
                      ),
                    ],
                  ),
                );
              },
            ),
            OutlinedButton.icon(
              onPressed: () => _confirmSignOut(context),
              icon: const Icon(Icons.logout),
              label: const Text('Sign out…'),
            ),
          ],
        );
      },
    );
  }

  /// Explicit choice the account-switch fix needs: keeping leaves this
  /// account's data on the device (isolated per account, restored on
  /// re-login); removing clears the device's views. Only synced items are
  /// guaranteed in the cloud — anything not yet synced stays in a per-account
  /// on-device backup that is restored only if this account signs back in
  /// here, and is never shown to the next account.
  Future<void> _confirmSignOut(BuildContext context) async {
    final engine = context.read<SyncEngine>();
    final choice = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'Synced tasks, events, finances and location history stay in '
          'your cloud account and download again on next sign-in. '
          'Removing clears them from this device, but anything not yet '
          'synced stays in a backup here — restored only if this account '
          'signs back in, never shown to the next account.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep on this device'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove from this device'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    engine.signOut(clearLocalData: choice);
  }

  String _formatAgo(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}

/// Demo replacement for [SyncSection]: mock-feed refresh + exit.
class _DemoSyncSection extends StatelessWidget {
  const _DemoSyncSection();

  @override
  Widget build(BuildContext context) {
    final feedCubit = context.read<FeedCubit>();
    return ValueListenableBuilder<bool>(
      valueListenable: feedCubit.isSyncing,
      builder: (context, syncing, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: syncing
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.science_outlined),
            title: Text(syncing ? 'Refreshing mock feeds…' : 'Demo sync'),
            subtitle: const Text(
              'Mock Canvas, Google and iCal feeds refresh locally. '
              'Submitted homework auto-completes, like the real thing.',
            ),
            trailing: TextButton(
              onPressed: syncing
                  ? null
                  : () => feedCubit.syncAll(force: true),
              child: const Text('Sync now'),
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => DemoCoordinator.exitDemo(context),
            icon: const Icon(Icons.logout),
            label: const Text('Exit demo (discards mock data)'),
          ),
        ],
      ),
    );
  }
}
