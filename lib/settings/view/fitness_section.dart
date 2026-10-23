import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../fitness/bloc/fitness_cubit.dart';

/// Strava connection card.
///
/// Garmin, Coros, Wahoo and Polar all push workouts into Strava, and any
/// Strava user can create a free API app — so Strava is the connector,
/// not a partner-gated watch API. Once connected, activities fill workout
/// tasks and activity goals. Strava has no sleep API, so sleep goals say
/// so instead of silently tracking zero.
class FitnessSection extends StatefulWidget {
  const FitnessSection({super.key});

  @override
  State<FitnessSection> createState() => _FitnessSectionState();
}

class _FitnessSectionState extends State<FitnessSection> {
  Timer? _poll;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<FitnessCubit>().refreshOnce();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (kIsWeb) {
      await launchUrl(uri, webOnlyWindowName: '_blank');
    } else {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _connect() async {
    final cubit = context.read<FitnessCubit>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final url = await cubit.connectUrl();
    if (!mounted) return;
    setState(() => _busy = false);
    if (url == null) {
      if (cubit.state.isConnected) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Strava connected.')),
        );
      } else if (cubit.state.link == FitnessLink.unconfigured) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('The server still needs a Strava API app — see '
                'the setup steps below.'),
          ),
        );
      } else if (cubit.state.error != null) {
        messenger.showSnackBar(
          SnackBar(content: Text(cubit.state.error!)),
        );
      }
      return;
    }
    await _open(url);
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Finish signing in on Strava, then come back here.'),
      ),
    );
    _startPolling();
  }

  /// The consent page lands in another tab, so the app can't observe the
  /// callback directly: re-check status for a minute after the tab opens.
  void _startPolling() {
    _poll?.cancel();
    final cubit = context.read<FitnessCubit>();
    var attempts = 0;
    _poll = Timer.periodic(const Duration(seconds: 3), (timer) async {
      attempts++;
      await cubit.refresh();
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (cubit.state.isConnected || attempts >= 20) {
        timer.cancel();
        if (cubit.state.isConnected) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Strava connected.')),
          );
        }
      }
    });
  }

  Future<void> _disconnect() async {
    final messenger = ScaffoldMessenger.of(context);
    final cubit = context.read<FitnessCubit>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect Strava?'),
        content: const Text(
          'Workout tasks already filled keep their reported time. New '
          'activities stop syncing until you connect again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await cubit.disconnect();
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Strava disconnected.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<FitnessCubit, FitnessState>(
      builder: (context, state) {
        final theme = Theme.of(context);
        final small = theme.textTheme.bodySmall;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                state.isConnected ? Icons.check_circle : Icons.watch_outlined,
                color: state.isConnected ? Colors.green : null,
              ),
              title: Text(
                state.isConnected
                    ? 'Connected as ${state.athlete ?? 'Strava athlete'}'
                    : 'Not connected',
              ),
              subtitle: Text(
                state.isConnected
                    ? _syncedLine(state)
                    : 'Garmin, Coros, Wahoo, and Polar push their workouts '
                        'to Strava. Connect Strava once and runs, rides, and '
                        'swims fill workout tasks and activity goals.',
              ),
            ),
            if (state.syncing)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (state.error != null) ...[
              const SizedBox(height: 4),
              Text(
                state.error!,
                style: small?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            if (state.link == FitnessLink.unconfigured)
              _SetupSteps(redirectUri: state.redirectUri),
            const SizedBox(height: 8),
            if (state.isConnected) ...[
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: state.syncing
                          ? null
                          : () => context.read<FitnessCubit>().sync(),
                      icon: const Icon(Icons.sync),
                      label: const Text('Sync activities'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _disconnect,
                    icon: const Icon(Icons.link_off),
                    label: const Text('Disconnect'),
                  ),
                ],
              ),
            ] else ...[
              FilledButton.icon(
                onPressed: _busy ? null : _connect,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.link),
                label: const Text('Connect Strava'),
              ),
              if (state.link == FitnessLink.unavailable)
                TextButton(
                  onPressed: () => context.read<FitnessCubit>().refresh(),
                  child: const Text('Try again'),
                ),
            ],
            const SizedBox(height: 8),
            Text(
              'Wearing a Garmin (or Coros, Wahoo, Polar)? In the Strava app: '
              'You → Settings → Connect an App or Device → Garmin. New '
              'workouts then reach this app through Strava, so you never '
              'give it your watch password.',
              style: small,
            ),
            if (!state.supportsSleep) ...[
              const SizedBox(height: 4),
              Text(
                'Sleep goals are not available: Strava does not expose '
                'sleep data.',
                style: small,
              ),
            ],
          ],
        );
      },
    );
  }

  String _syncedLine(FitnessState state) {
    final count = state.activities.length;
    final noun = count == 1 ? 'activity' : 'activities';
    final synced = state.lastSync;
    if (synced == null) return '$count $noun in the last 30 days.';
    final minutes = DateTime.now().difference(synced).inMinutes;
    final when = minutes < 1 ? 'just now' : '$minutes min ago';
    return '$count $noun in the last 30 days · synced $when.';
  }
}

/// Server-side setup: no Strava API app yet. Shown inline so the fix is
/// one click away instead of a developer-endpoint explanation.
class _SetupSteps extends StatelessWidget {
  final String? redirectUri;

  const _SetupSteps({this.redirectUri});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Server setup needed', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            '1. Create a free Strava API app (any Strava account can).',
            style: small,
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => launchUrl(
                Uri.parse('https://www.strava.com/settings/api'),
                webOnlyWindowName: '_blank',
              ),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Open strava.com/settings/api'),
            ),
          ),
          Text(
            '2. Set STRAVA_CLIENT_ID and STRAVA_CLIENT_SECRET in the '
            'server environment (server/.env), then restart the server.',
            style: small,
          ),
          if (redirectUri != null && redirectUri!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('3. Use this Authorization Callback Domain/URL:', style: small),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    redirectUri!,
                    style: small?.copyWith(fontFamily: 'monospace'),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy callback URL',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: redirectUri!),
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Callback URL copied.')),
                    );
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
