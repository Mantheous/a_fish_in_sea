import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../demo/demo_cubit.dart';
import '../../auth_cubit.dart';
import 'auth_page.dart';
import 'login_wave.dart';

/// Swaps between the sign-in scene and the app, keeping the sign-in page on
/// screen while a white-crested wave of sea-blue drains down and reveals the
/// app above it.
///
/// The whole thing is one [Stack] with stable slots, so the [AuthPage]'s
/// state (focus, typed text) survives the moment the auth state flips. The
/// wave accelerates with [Curves.easeInQuad] — it gathers, then falls.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.child});

  /// The signed-in application shell.
  final Widget child;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate>
    with SingleTickerProviderStateMixin {
  static const Duration _waveDuration = Duration(milliseconds: 1150);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _waveDuration,
  )..addStatusListener(_onWaveStatus);
  late final Animation<double> _fall = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInQuad,
  );

  late bool _signedIn;
  bool _showLogin = true;
  bool _waving = false;

  @override
  void initState() {
    super.initState();
    // A reload with a stored token must land straight in the app, with no
    // wave: only a live signed-out -> signed-in flip plays the animation.
    _signedIn = _isSignedIn();
    _showLogin = !_signedIn;
  }

  bool _isSignedIn() =>
      context.read<AuthCubit>().state.isSignedIn ||
      context.read<DemoCubit>().state;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final signedIn =
        context.watch<AuthCubit>().state.isSignedIn ||
        context.watch<DemoCubit>().state;
    if (signedIn == _signedIn) return;

    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    setState(() {
      _signedIn = signedIn;
      if (!signedIn) {
        _showLogin = true;
        _waving = false;
        _controller.value = 0;
        return;
      }
      // Reduced motion: reveal instantly, no falling wave.
      _showLogin = !reduceMotion;
      _waving = !reduceMotion;
    });
    if (_waving) _controller.forward(from: 0);
  }

  void _onWaveStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    setState(() {
      _waving = false;
      _showLogin = false;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_waving && !_showLogin) return widget.child;
    return AnimatedBuilder(
      animation: _fall,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            final geometry = WaveGeometry(
              size: size,
              progress: _waving ? _fall.value : 0,
            );
            return Stack(
              children: [
                // Slot 0: the app, built underneath so it is ready (and
                // already loading) the moment the crest reveals it.
                Positioned.fill(
                  child: _signedIn ? widget.child : const SizedBox.shrink(),
                ),
                // Slot 1: the falling sea. Transparent above the crest, so
                // the app shows through there.
                Positioned.fill(
                  child: _waving
                      ? IgnorePointer(
                          child: CustomPaint(
                            key: loginWaveOverlayKey,
                            painter: LoginWavePainter(geometry: geometry),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                // Slot 2: the sign-in scene, clipped to the water still on
                // screen so it rides the back of the wave. Kept in the same
                // slot while leaving, so its state is preserved.
                Positioned.fill(
                  child: _showLogin
                      ? ClipPath(
                          clipper: WavePageClipper(geometry),
                          child: IgnorePointer(
                            ignoring: _waving,
                            child: const AuthPage(),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
