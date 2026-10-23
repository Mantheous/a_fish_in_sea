import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'sea_theme.dart';

/// Height of the strip reserved for the fish above the sign-in card.
const double kFishLaneHeight = 98;

/// A goldfish that slowly crosses the sign-in screen and loops back in from
/// the left. Drawn as vectors (rather than cropping the PNG logo) so it stays
/// crisp at any density, and kept cheap: one repaint boundary, one path set.
///
/// Motion is deliberately unhurried (a full crossing takes [duration]) with a
/// light bob and tail swish. A full loop spends time fully off-screen at both
/// ends, so the wrap is invisible.
class SwimmingFish extends StatefulWidget {
  const SwimmingFish({
    super.key,
    this.duration = const Duration(seconds: 19),
    this.fishWidth = 150,
  });

  final Duration duration;
  final double fishWidth;

  @override
  State<SwimmingFish> createState() => _SwimmingFishState();
}

class _SwimmingFishState extends State<SwimmingFish>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion == _reduceMotion) return;
    _reduceMotion = reduceMotion;
    if (_reduceMotion) {
      _controller.stop();
    } else {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fishHeight = widget.fishWidth * 0.6;
    return ExcludeSemantics(
      child: SizedBox(
        height: kFishLaneHeight,
        width: double.infinity,
        child: ClipRect(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final travel = constraints.maxWidth + widget.fishWidth * 2;
              return AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  // Static, parked mid-lane when animations are disabled.
                  final t = _reduceMotion ? 0.33 : _controller.value;
                  final x = -widget.fishWidth + travel * t;
                  // Four gentle bobs and a slight nose tilt per crossing;
                  // the tail swishes about once a second.
                  final bob = math.sin(t * math.pi * 8) * 5;
                  final tilt = math.sin(t * math.pi * 8 + 0.6) * 0.04;
                  final swish = math.sin(
                    t * math.pi * 2 * widget.duration.inSeconds,
                  );
                  return Stack(
                    children: [
                      Positioned(
                        left: x,
                        top: (kFishLaneHeight - fishHeight) / 2 + bob,
                        width: widget.fishWidth,
                        height: fishHeight,
                        child: Transform.rotate(
                          angle: tilt,
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: _FishPainter(swish: swish),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Flat, logo-matching goldfish facing right in a 200x120 design box.
class _FishPainter extends CustomPainter {
  const _FishPainter({required this.swish});

  /// -1..1 tail position.
  final double swish;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 200;
    canvas.save();
    canvas.scale(scale);

    final bodyPaint = Paint()..color = SeaPalette.fish;
    final finPaint = Paint()..color = SeaPalette.fishFin;
    final inkPaint = Paint()..color = SeaPalette.nightBlue;

    // Tail swishes around its joint with the body.
    canvas.save();
    canvas.translate(64, 60);
    canvas.rotate(swish * 0.16);
    canvas.translate(-64, -60);
    final tail = Path()
      ..moveTo(66, 60)
      ..cubicTo(50, 50, 24, 20, 12, 26)
      ..cubicTo(2, 32, 20, 52, 34, 60)
      ..cubicTo(20, 68, 2, 88, 12, 94)
      ..cubicTo(24, 100, 50, 70, 66, 60)
      ..close();
    canvas.drawPath(tail, finPaint);
    canvas.restore();

    // Dorsal and pelvic fins sit behind the body so their roots are hidden.
    final dorsal = Path()
      ..moveTo(100, 30)
      ..cubicTo(94, 8, 70, 0, 65, 6)
      ..cubicTo(73, 20, 80, 32, 88, 40)
      ..close();
    canvas.drawPath(dorsal, finPaint);

    final pelvic = Path()
      ..moveTo(102, 90)
      ..cubicTo(102, 110, 114, 120, 126, 118)
      ..cubicTo(121, 106, 120, 94, 123, 86)
      ..close();
    canvas.drawPath(pelvic, finPaint);

    final body = Path()
      ..moveTo(62, 60)
      ..cubicTo(70, 32, 98, 22, 124, 24)
      ..cubicTo(156, 26, 180, 42, 186, 57)
      ..cubicTo(191, 68, 176, 84, 152, 94)
      ..cubicTo(118, 106, 78, 96, 62, 60)
      ..close();
    canvas.drawPath(body, bodyPaint);

    // Gill crease.
    final gill = Path()
      ..moveTo(128, 30)
      ..cubicTo(143, 46, 143, 76, 128, 92);
    canvas.drawPath(
      gill,
      Paint()
        ..color = SeaPalette.fishFin
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );

    // Pectoral fin.
    canvas.save();
    canvas.translate(116, 78);
    canvas.rotate(-0.5);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 30, height: 16),
      finPaint,
    );
    canvas.restore();

    // Eye: white sclera, dark pupil, small highlight.
    canvas.drawCircle(const Offset(152, 52), 13, Paint()..color = Colors.white);
    canvas.drawCircle(const Offset(155, 52), 8, inkPaint);
    canvas.drawCircle(
      const Offset(151.5, 48.5),
      2.6,
      Paint()..color = Colors.white,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_FishPainter oldDelegate) => oldDelegate.swish != swish;
}
