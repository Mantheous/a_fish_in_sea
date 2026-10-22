import 'package:a_fish_in_sea/demo/demo_mode.dart';
import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Lists, creates, and revokes scoped `afm_…` tokens (server
/// `POST/GET/DELETE /api/v1/tokens`). Plaintext secrets are shown once
/// in a copy dialog and never persisted on device.
class ApiTokensSection extends StatefulWidget {
  const ApiTokensSection({super.key});

  @override
  State<ApiTokensSection> createState() => _ApiTokensSectionState();
}

class _ApiTokensSectionState extends State<ApiTokensSection> {
  List<ApiToken>? _tokens;
  String? _error;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  SyncClient get _client => context.read<AuthCubit>().syncClient;

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tokens = await _client.listApiTokens();
      if (!mounted) return;
      setState(() => _tokens = tokens);
    } on SyncException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    final spec = await showDialog<_TokenSpec>(
      context: context,
      builder: (dialogContext) => const _CreateTokenDialog(),
    );
    if (spec == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final created = await _client.createApiToken(
        name: spec.name,
        review: spec.review,
      );
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) =>
            _ShowTokenDialog(secret: created.token, name: created.info.name),
      );
    } on SyncException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create token: ${e.message}')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(ApiToken token) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Revoke token?'),
        content: Text(
          '“${token.name.isEmpty ? 'Unnamed token' : token.name}” (${token.prefix}…) '
          'will stop working immediately. Apps using it will lose sync access.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _client.revokeApiToken(token.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Token revoked.')),
      );
      await _load();
    } on SyncException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not revoke token: ${e.message}')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (DemoMode.isActive) {
      return const Text(
        'API tokens need a real account — unavailable in demo mode.',
      );
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Could not load tokens: $_error',
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      );
    }
    final tokens = _tokens ?? const <ApiToken>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (tokens.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('No tokens yet. Create one per app or agent.'),
          )
        else
          for (final token in tokens)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.key_outlined),
              title: Text(token.name.isEmpty ? 'Unnamed token' : token.name),
              subtitle: Text(
                '${token.prefix}… · full sync access'
                '${token.review ? ' · needs approval' : ''}',
              ),
              trailing: IconButton(
                tooltip: 'Revoke',
                onPressed: _busy ? null : () => _revoke(token),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: _busy ? null : _create,
          icon: const Icon(Icons.add),
          label: const Text('Create token'),
        ),
      ],
    );
  }
}

class _TokenSpec {
  final String name;
  final bool review;
  const _TokenSpec({required this.name, required this.review});
}

class _CreateTokenDialog extends StatefulWidget {
  const _CreateTokenDialog();

  @override
  State<_CreateTokenDialog> createState() => _CreateTokenDialogState();
}

class _CreateTokenDialogState extends State<_CreateTokenDialog> {
  final _name = TextEditingController();
  bool _review = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create API token'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'Name (e.g. Claude on laptop)',
              border: OutlineInputBorder(),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Needs approval'),
            subtitle: const Text(
              'On: this token drafts into the import inbox instead of '
              'writing directly. Use for untrusted writers.',
            ),
            value: _review,
            onChanged: (v) => setState(() => _review = v),
          ),
          const Text(
            'Tokens get full sync access (read + write everything). '
            'Copy the secret right away — it is shown only once.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _TokenSpec(name: _name.text.trim(), review: _review),
          ),
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class _ShowTokenDialog extends StatelessWidget {
  final String secret;
  final String name;
  const _ShowTokenDialog({required this.secret, required this.name});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Copy your token'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (name.isNotEmpty) Text('“$name” — copy it now.'),
          if (name.isEmpty) const Text('Copy it now.'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(secret),
          ),
          const SizedBox(height: 8),
          const Text(
            'This is the only time the secret is shown. '
            'If you lose it, revoke this token and create a new one.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: secret));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Token copied.')),
              );
              Navigator.of(context).pop();
            }
          },
          icon: const Icon(Icons.copy),
          label: const Text('Copy'),
        ),
      ],
    );
  }
}
