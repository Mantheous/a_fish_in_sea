import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'sea_theme.dart';

/// Geometry of the sign-in wave as it drains down the screen.
///
/// [progress] runs 0 → 1. At 0 the sea covers the whole screen (the crest
/// sits just above the top edge); at 1 the crest is past the bottom edge and
/// the app above it is fully visible.
///
/// The crest is a white foam ribbon with a wavy top and a slightly offset
/// wavy bottom, echoing the triple waves in the logo. Geometry is shared by
/// the painter and the clip that masks the login page, so the page is never
/// visible above the foam.
@immutable
class WaveGeometry {
  const WaveGeometry({required this.size, required this.progress})
    : assert(progress >= 0 && progress <= 1);

  final Size size;
  final double progress;

  static const double bandHeight = 54;
  static const double amplitude = 14;

  double get wavelength => math.max(size.width * 0.56, 260);

  double get phase => -progress * math.pi * 3;

  /// Y of the foam ribbon's top edge, before the wave offset.
  double get startY =>
      -bandHeight -
      amplitude * 2 +
      progress * (size.height + bandHeight + amplitude * 4);

  double topAt(double x) =>
      startY + amplitude * math.sin(2 * math.pi * x / wavelength + phase);

  double bottomAt(double x) =>
      startY +
      bandHeight +
      amplitude * 0.65 * math.sin(2 * math.pi * x / wavelength + phase + 0.9);

  int get _steps => math.max(24, (size.width / 16).ceil());

  double _xAt(int step) => size.width * step / _steps;

  /// Everything at or below the ribbon (the log-in page lives here while the
  /// sea falls past it).
  Path clipPath() {
    final path = Path()..moveTo(0, topAt(0));
    for (var i = 1; i <= _steps; i++) {
      path.lineTo(_xAt(i), topAt(_xAt(i)));
    }
    path
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    return path;
  }

  /// The white foam ribbon itself.
  Path foamPath() {
    final path = Path()..moveTo(0, topAt(0));
    for (var i = 1; i <= _steps; i++) {
      path.lineTo(_xAt(i), topAt(_xAt(i)));
    }
    for (var i = _steps; i >= 0; i--) {
      path.lineTo(_xAt(i), bottomAt(_xAt(i)));
    }
    path.close();
    return path;
  }

  /// The deep blue water under the foam.
  Path seaPath() {
    final path = Path()..moveTo(0, bottomAt(0));
    for (var i = 1; i <= _steps; i++) {
      path.lineTo(_xAt(i), bottomAt(_xAt(i)));
    }
    path
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    return path;
  }

  /// A thin foam trail floating just above the crest.
  Path foamTrailPath() {
    final trail = Path();
    for (var i = 0; i <= _steps; i++) {
      final x = _xAt(i);
      final y =
          topAt(x) -
          22 +
          7 * math.sin(2 * math.pi * x / (wavelength * 0.78) + phase * 1.4);
      if (i == 0) {
        trail.moveTo(x, y);
      } else {
        trail.lineTo(x, y);
      }
    }
    return trail;
  }
}

/// Clips the login page to the part the falling sea still covers.
class WaveClipClipper extends CustomClipper<Path> {
  const WaveClipClipper(this.geometry);

  final WaveGeometry geometry;

  @override
  Path getClip(Size size) => geometry.clipPath();

  @override
  bool shouldReclip(WaveClipClipper oldClipper) =>
      oldClipper.geometry.progress != geometry.progress ||
      oldClipper.geometry.size != geometry.size;
}

/// Paints the draining sea: foam ribbon, soft shadow, trail, and the blue
/// water below it. Everything above the ribbon is transparent.
class LoginWavePainter extends CustomPainter {
  const LoginWavePainter({required this.geometry});

  final WaveGeometry geometry;

  @override
  void paint(Canvas canvas, Size size) {
    final foam = geometry.foamPath();

    canvas.drawPath(geometry.seaPath(), Paint()..color = SeaPalette.blue);

    // Soft depth under the white ribbon so it reads as a breaking wave.
    canvas.save();
    canvas.translate(0, 7);
    canvas.drawPath(
      foam,
      Paint()
        ..color = SeaPalette.nightBlue.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );
    canvas.restore();

    canvas.drawPath(foam, Paint()..color = Colors.white);

    canvas.drawPath(
      geometry.foamTrailPath(),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(LoginWavePainter oldDelegate) =>
      oldDelegate.geometry.progress != geometry.progress ||
      oldDelegate.geometry.size != geometry.size;
}

/// Key used by widget tests to find the falling wave.
const Key loginWaveOverlayKey = Key('login-wave-overlay');
