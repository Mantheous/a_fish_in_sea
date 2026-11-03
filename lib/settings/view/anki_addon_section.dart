import 'dart:convert';

import 'package:a_fish_in_sea/anki/anki_reports.dart';
import 'package:a_fish_in_sea/anki/anki_reports_cubit.dart';
import 'package:a_fish_in_sea/common/time/local_date.dart';
import 'package:a_fish_in_sea/demo/demo_mode.dart';
import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';

/// Settings → Anki: add-on status, setup, and a scoped token.
///
/// The add-on runs inside desktop Anki and pushes daily deck totals to
/// the server. This section is the only place the token is minted; it is
/// shown once inside the copyable config JSON.
class AnkiAddonSection extends StatefulWidget {
  const AnkiAddonSection({super.key});

  @override
  State<AnkiAddonSection> createState() => _AnkiAddonSectionState();
}

class _AnkiAddonSectionState extends State<AnkiAddonSection> {
  bool _creating = false;

  SyncClient get _client => context.read<AuthCubit>().syncClient;

  @override
  void initState() {
    super.initState();
    // Opening the section is a natural "show me now" moment. The cubit
    // also refreshes on a timer and on sign-in; this call collapses with
    // any in-flight request.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || DemoMode.isActive) return;
      if (context.read<AuthCubit>().state.isSignedIn) {
        context.read<AnkiReportsCubit>().refresh();
      }
    });
  }

  Future<void> _downloadAddon() async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.parse('${_client.baseUrl}/api/v1/anki/addon');
    try {
      await launchUrl(uri, webOnlyWindowName: '_blank');
    } catch (_) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('Could not open the download: $e')),
        );
      }
    }
  }

  Future<void> _createToken() async {
    setState(() => _creating = true);
    try {
      final created = await _client.createApiToken(
        name: 'Anki add-on',
        scopes: const ['anki:write'],
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _AnkiSetupDialog(secret: created.token, serverUrl: _client.baseUrl),
      );
      if (mounted) context.read<AnkiReportsCubit>().refresh();
    } on SyncException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create the token: ${e.message}')),
      );
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (DemoMode.isActive) {
      return const Text(
        'Anki reports need a real account — unavailable in demo mode.',
      );
    }
    final auth = context.watch<AuthCubit>();
    if (!auth.state.isSignedIn) {
      return const Text(
        'Sign in to connect the Anki add-on. Reports are stored per '
        'account so every device sees the same counts.',
      );
    }
    final state = context.watch<AnkiReportsCubit>().state;
    final theme = Theme.of(context);
    final data = state.data;
    final recentCards = _recentCards(data.days);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              data.lastReportAt == null
                  ? Icons.hourglass_empty
                  : Icons.cloud_done_outlined,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                data.lastReportAt == null
                    ? 'No add-on reports yet'
                    : 'Last report ${_ago(data.lastReportAt!)}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            IconButton(
              tooltip: 'Refresh reports',
              onPressed: state.isLoading
                  ? null
                  : () => context.read<AnkiReportsCubit>().refresh(),
              icon: state.isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        if (data.lastReportAt != null)
          Padding(
            padding: const EdgeInsets.only(left: 28, bottom: 4),
            child: Text(
              '${data.decks.length} deck${data.decks.length == 1 ? '' : 's'} '
              'with data · $recentCards card${recentCards == 1 ? '' : 's'} '
              'in the last 7 days',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (state.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              state.error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        if (data.decks.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('Decks the add-on has seen', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final deck in data.decks.take(12))
                Chip(
                  label: Text(deck.name),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              if (data.decks.length > 12)
                Chip(
                  label: Text('+${data.decks.length - 12} more'),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Goal deck names match subdecks too: a goal on “Japanese” '
            'counts “Japanese::Vocab”.',
            style: theme.textTheme.bodySmall,
          ),
        ],
        const Divider(height: 24),
        Text('Set up the add-on', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(
          '1. Download the add-on and install it in Anki (Tools → Add-ons '
          '→ Install from file).\n'
          '2. Create a token here.\n'
          '3. Paste the config JSON into Tools → Add-ons → A Fish in Sea → '
          'Config, then run Tools → A Fish in Sea: Test connection.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _downloadAddon,
          icon: const Icon(Icons.download_outlined),
          label: const Text('Download add-on (.ankiaddon)'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _creating ? null : _createToken,
          icon: _creating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.key_outlined),
          label: const Text('Create add-on token'),
        ),
        const SizedBox(height: 4),
        Text(
          'The token is write-only: it can submit review totals but cannot '
          'read your goals, calendar, or notes. Reports contain deck names '
          'and daily counts — never card text.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  static int _recentCards(List<AnkiReviewDay> days) {
    final cutoff = shiftLocalDay(localDay(DateTime.now()), -6);
    var total = 0;
    for (final row in days) {
      if (!row.day.isBefore(cutoff)) total += row.cards;
    }
    return total;
  }

  static String _ago(DateTime moment) {
    final delta = DateTime.now().difference(moment.toLocal());
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
    if (delta.inHours < 24) return '${delta.inHours} h ago';
    return '${delta.inDays} d ago';
  }
}

class _AnkiSetupDialog extends StatelessWidget {
  final String secret;
  final String serverUrl;

  const _AnkiSetupDialog({required this.secret, required this.serverUrl});

  String get _config => const JsonEncoder.withIndent('  ').convert({
    'server_url': serverUrl,
    'api_token': secret,
    'enabled': true,
    'report_days': 400,
    'rollover_hour': 0,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Anki add-on config'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Paste this into Tools → Add-ons → A Fish in Sea → Config. '
                'The token is shown only once.',
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  _config,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'report_days controls how much history is resent (400 by '
                'default). rollover_hour defaults to 0 = local midnight, '
                'matching the app calendar.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: _config));
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Config copied.')));
            }
          },
          icon: const Icon(Icons.copy),
          label: const Text('Copy config'),
        ),
      ],
    );
  }
}
