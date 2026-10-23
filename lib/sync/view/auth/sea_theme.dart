import 'package:flutter/material.dart';

/// Palette sampled from `assets/images/app_logo.png`, so the sign-in scene
/// and the animated wave stay in the same family as the app icon.
abstract final class SeaPalette {
  /// The logo's ocean blue.
  static const Color blue = Color(0xFF0561A4);

  /// Darker blue used for depth (shadows, sea floor).
  static const Color deepBlue = Color(0xFF023E6B);

  /// The fish's pupil / night water.
  static const Color nightBlue = Color(0xFF062A4A);

  /// The goldfish body orange.
  static const Color fish = Color(0xFFFB8E0B);

  /// Fins and tail: a shade deeper than the body.
  static const Color fishFin = Color(0xFFEE7103);
}

/// Type for the sign-in scene. Fredoka is bundled (OFL, `assets/fonts`)
/// rather than fetched at runtime: the app is offline-first and the web
/// build must render the wordmark on the very first frame.
abstract final class SeaType {
  static const String family = 'Fredoka';

  static TextStyle wordmark({double size = 46}) => TextStyle(
    fontFamily: family,
    fontVariations: const [FontVariation('wght', 600)],
    fontWeight: FontWeight.w600,
    fontSize: size,
    height: 1.02,
    letterSpacing: 0.4,
    color: Colors.white,
    shadows: const [
      Shadow(color: Color(0x6601243F), blurRadius: 18, offset: Offset(0, 6)),
    ],
  );

  static TextStyle tagline({double size = 11}) => TextStyle(
    fontFamily: family,
    fontVariations: const [FontVariation('wght', 500)],
    fontWeight: FontWeight.w500,
    fontSize: size,
    height: 1.2,
    letterSpacing: 3.1,
    color: Colors.white.withValues(alpha: 0.78),
  );
}
