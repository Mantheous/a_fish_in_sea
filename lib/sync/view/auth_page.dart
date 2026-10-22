import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../demo/demo_coordinator.dart';
import '../auth_cubit.dart';
import '../sync_engine.dart';
import '../sync_meta_cubit.dart';

/// Email + password gate for the sync server.
///
/// Conflict policy (also in SyncEngine docs): per-item last-write-wins,
/// server wins true conflicts. Undo history stays on-device, so a bad
/// merge is still undoable locally.
class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit(Future<bool> Function(String, String) call) async {
    final email = _email.text.trim();
    if (email.isEmpty || _password.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter an email and password.')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final ok = await call(email, _password.text);
      if (!mounted) return;
      if (ok) {
        // Reset cursor/items (preserving lastEmail so SyncEngine detects
        // account switches and never merges another user's local data).
        context.read<SyncMetaCubit>().reset();
        await context.read<SyncEngine>().syncNow();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthCubit>().state;
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in to sync')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: AutofillGroup(
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                const Text(
                  'Sign in to sync your planner, finances and goals '
                  'across web, mobile, and AI agents.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _email,
                  focusNode: _emailFocus,
                  autofocus: true,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  autocorrect: false,
                  onSubmitted: (_) => _passwordFocus.requestFocus(),
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  focusNode: _passwordFocus,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) =>
                      _submit(context.read<AuthCubit>().login),
                decoration: const InputDecoration(
                  labelText: 'Password (8+ characters)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              if (auth.error != null) ...[
                const SizedBox(height: 12),
                Text(auth.error!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _submit(context.read<AuthCubit>().login),
                child: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Sign in'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _submit(context.read<AuthCubit>().register),
                child: const Text('Create account'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Google sign-in (one-tap login) is still to come — '
                        'this server already keeps each account\'s Google '
                        'calendars separate. Use email + password for now.',
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.g_mobiledata),
                label: const Text('Continue with Google (soon)'),
              ),
              const SizedBox(height: 16),
              const Text(
                'Sync is offline-first: this device keeps working without a '
                'connection and merges later. If the same item changes on '
                'two devices, the server copy wins.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              const Text(
                'Just looking around? Tour the whole app — calendar, '
                'tasks, finances, stats and every integration — on mock '
                'data. Nothing is saved and no account is needed.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: _busy
                    ? null
                    : () => DemoCoordinator.enterDemo(context),
                icon: const Icon(Icons.science_outlined),
                label: const Text('Try demo mode (no sign-in)'),
              ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
