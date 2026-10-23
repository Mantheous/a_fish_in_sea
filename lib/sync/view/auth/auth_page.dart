import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../demo/demo_coordinator.dart';
import '../../auth_cubit.dart';
import '../../sync_engine.dart';
import '../../sync_meta_cubit.dart';
import 'sea_theme.dart';
import 'swimming_fish.dart';

/// White-card theme, pinned to light so the card stays readable when the
/// system (or the app theme) is dark. The page around it is always the
/// logo-blue sea.
final ThemeData _cardTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: SeaPalette.blue),
);

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
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: SeaPalette.blue,
        body: Stack(
          children: [
            const Positioned.fill(child: CustomPaint(painter: _SeaPainter())),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    padding: const EdgeInsets.only(top: 30, bottom: 26),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 24),
                            child: _Wordmark(),
                          ),
                          const SizedBox(height: 10),
                          const SwimmingFish(),
                          const SizedBox(height: 20),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 430),
                              child: _buildCard(auth),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(AuthState auth) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: SeaPalette.nightBlue.withValues(alpha: 0.32),
            blurRadius: 42,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
      child: Theme(
        data: _cardTheme,
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Sign in to sync',
                style: TextStyle(
                  fontFamily: SeaType.family,
                  fontVariations: const [FontVariation('wght', 600)],
                  fontWeight: FontWeight.w600,
                  fontSize: 25,
                  height: 1.1,
                  color: SeaPalette.deepBlue,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Your planner, finances and goals across web, mobile, and '
                'AI agents.',
                style: _cardTheme.textTheme.bodySmall?.copyWith(
                  color: SeaPalette.nightBlue.withValues(alpha: 0.66),
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _email,
                focusNode: _emailFocus,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                autocorrect: false,
                onSubmitted: (_) => _passwordFocus.requestFocus(),
                decoration: InputDecoration(
                  labelText: 'Email',
                  prefixIcon: const Icon(Icons.alternate_email, size: 20),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                focusNode: _passwordFocus,
                obscureText: true,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.password],
                onSubmitted: (_) => _submit(context.read<AuthCubit>().login),
                decoration: InputDecoration(
                  labelText: 'Password (8+ characters)',
                  prefixIcon: const Icon(Icons.lock_outline, size: 20),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              if (auth.error != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFDECEC),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    auth.error!,
                    style: TextStyle(
                      color: _cardTheme.colorScheme.error,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              FilledButton(
                style: _primaryButtonStyle,
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
                style: _secondaryButtonStyle,
                onPressed: _busy
                    ? null
                    : () => _submit(context.read<AuthCubit>().register),
                child: const Text('Create account'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                style: _secondaryButtonStyle,
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
              Text(
                'Offline-first: this device keeps working without a '
                'connection and merges later. If the same item changes on '
                'two devices, the server copy wins.',
                style: _cardTheme.textTheme.bodySmall?.copyWith(
                  fontSize: 11.5,
                  height: 1.35,
                  color: SeaPalette.nightBlue.withValues(alpha: 0.5),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Divider(height: 1),
              ),
              Text(
                'Just looking around? Tour the whole app — calendar, tasks, '
                'finances, stats and every integration — on mock data. '
                'Nothing is saved and no account is needed.',
                style: _cardTheme.textTheme.bodySmall?.copyWith(
                  fontSize: 11.5,
                  height: 1.35,
                  color: SeaPalette.nightBlue.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                style: _demoButtonStyle,
                onPressed: _busy
                    ? null
                    : () => DemoCoordinator.enterDemo(context),
                icon: const Icon(Icons.science_outlined, size: 20),
                label: const Text('Try demo mode (no sign-in)'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final ButtonStyle _primaryButtonStyle = FilledButton.styleFrom(
  backgroundColor: SeaPalette.blue,
  foregroundColor: Colors.white,
  minimumSize: const Size.fromHeight(50),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
  textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
);

final ButtonStyle _secondaryButtonStyle = OutlinedButton.styleFrom(
  foregroundColor: SeaPalette.blue,
  side: BorderSide(color: SeaPalette.blue.withValues(alpha: 0.32)),
  minimumSize: const Size.fromHeight(46),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
  textStyle: const TextStyle(fontWeight: FontWeight.w600),
);

final ButtonStyle _demoButtonStyle = FilledButton.styleFrom(
  backgroundColor: const Color(0xFFE7F2FB),
  foregroundColor: SeaPalette.deepBlue,
  minimumSize: const Size.fromHeight(46),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
  textStyle: const TextStyle(fontWeight: FontWeight.w600),
);

/// App name above the sign-in card, in the bundled rounded display face.
class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(46);
    final size = math.min(scale, 54.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(
            'AFishInSea',
            textAlign: TextAlign.center,
            maxLines: 1,
            style: SeaType.wordmark(size: size),
          ),
        ),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            'PLANNER · FINANCES · GOALS',
            textAlign: TextAlign.center,
            style: SeaType.tagline(),
          ),
        ),
      ],
    );
  }
}

/// Solid logo-blue sea with a faint echo of the logo's wave strokes near
/// the top. Everything is painted, so the page has no image decode cost.
class _SeaPainter extends CustomPainter {
  const _SeaPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = SeaPalette.blue);

    final baseY = size.height < 620 ? 18.0 : 30.0;
    for (var line = 0; line < 3; line++) {
      final path = Path();
      final y = baseY + line * 34.0;
      final wavelength = math.max(size.width * 0.34, 250.0);
      for (var i = 0; i <= 64; i++) {
        final x = size.width * i / 64;
        final dy = 11 * math.sin(2 * math.pi * x / wavelength + line * 0.9);
        if (i == 0) {
          path.moveTo(x, y + dy);
        } else {
          path.lineTo(x, y + dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.09 - line * 0.022)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_SeaPainter oldDelegate) => false;
}
