import 'dart:math' as math;

import 'package:flutter/material.dart';

const int _dayMinutes = 24 * 60;

/// Dial angle in radians, measured clockwise from 12 o'clock, for a
/// minute-of-day in [0, 1440).
double dialAngleForMinutes(int minutes) {
  final m = minutes % _dayMinutes;
  if (m < 0) return (m + _dayMinutes) / _dayMinutes * math.pi * 2;
  return m / _dayMinutes * math.pi * 2;
}

/// Minute-of-day in [0, 1440) for a dial angle measured clockwise from
/// 12 o'clock (as produced by `atan2(dx, -dy)`).
int minutesForDialAngle(double angle) {
  final twoPi = math.pi * 2;
  var a = angle % twoPi;
  if (a < 0) a += twoPi;
  return (a / twoPi * _dayMinutes).round() % _dayMinutes;
}

/// Snaps [minutes] to the nearest [snap]-minute grid, wrapping past
/// midnight (1439 + snap -> 0).
int snapDayMinutes(int minutes, int snap) {
  if (snap <= 1) return minutes % _dayMinutes;
  final snapped = ((minutes + snap ~/ 2) ~/ snap) * snap;
  return snapped % _dayMinutes;
}

/// Clockwise distance in minutes from [from] to [to], both minute-of-day.
/// Wraps through midnight, so the range is always in [0, 1440).
int clockwiseMinutes(int from, int to) => (to - from) % _dayMinutes;

int timeOfDayMinutes(TimeOfDay t) => (t.hour * 60 + t.minute) % _dayMinutes;

TimeOfDay timeOfDayFromMinutes(int m) {
  final v = m % _dayMinutes;
  return TimeOfDay(hour: v ~/ 60, minute: v % 60);
}

String formatDialDuration(int minutes) {
  final m = minutes % _dayMinutes;
  if (m < 60) return '${m}m';
  final h = m ~/ 60;
  final rest = m % 60;
  return rest == 0 ? '${h}h' : '${h}h ${rest}m';
}

enum _DialHandle { start, end }

/// Circular 24-hour editor for a start/stop time range.
///
/// Midnight sits at the top, time runs clockwise, and the selected range
/// is drawn as an arc between two draggable circular handles (the same
/// white-circle look as the calendar's resize handles). Ranges may wrap
/// past midnight. Precision edits stay available through the regular time
/// fields next to the dial.
class TimeRangeDial extends StatefulWidget {
  final TimeOfDay start;
  final TimeOfDay end;
  final ValueChanged<TimeOfDay> onStartChanged;
  final ValueChanged<TimeOfDay> onEndChanged;
  final int snapMinutes;
  final double size;

  const TimeRangeDial({
    super.key,
    required this.start,
    required this.end,
    required this.onStartChanged,
    required this.onEndChanged,
    this.snapMinutes = 5,
    this.size = 208,
  });

  @override
  State<TimeRangeDial> createState() => _TimeRangeDialState();
}

class _TimeRangeDialState extends State<TimeRangeDial> {
  _DialHandle? _active;

  int get _snap => widget.snapMinutes <= 0 ? 1 : widget.snapMinutes;

  int _minutesAt(Offset local) {
    final half = widget.size / 2;
    final dx = local.dx - half;
    final dy = local.dy - half;
    return minutesForDialAngle(math.atan2(dx, -dy));
  }

  static int _circularDist(int a, int b) {
    final d = (a - b).abs() % _dayMinutes;
    return math.min(d, _dayMinutes - d);
  }

  void _grabNearest(int touchMinutes) {
    final s = timeOfDayMinutes(widget.start);
    final e = timeOfDayMinutes(widget.end);
    final ds = _circularDist(touchMinutes, s);
    final de = _circularDist(touchMinutes, e);
    _active = de < ds ? _DialHandle.end : _DialHandle.start;
    _moveTo(touchMinutes);
  }

  void _moveTo(int minutes) {
    final value = timeOfDayFromMinutes(snapDayMinutes(minutes, _snap));
    if (_active == _DialHandle.end) {
      if (value != widget.end) widget.onEndChanged(value);
    } else if (_active == _DialHandle.start) {
      if (value != widget.start) widget.onStartChanged(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final startMin = timeOfDayMinutes(widget.start);
    final endMin = timeOfDayMinutes(widget.end);
    final duration = clockwiseMinutes(startMin, endMin);
    return Semantics(
      container: true,
      label:
          'Adjust time range: starts ${widget.start.format(context)}, ends ${widget.end.format(context)}',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanDown: (details) =>
                setState(() => _grabNearest(_minutesAt(details.localPosition))),
            onPanUpdate: (details) =>
                _moveTo(_minutesAt(details.localPosition)),
            onPanEnd: (_) => setState(() => _active = null),
            onPanCancel: () => setState(() => _active = null),
            child: CustomPaint(
              size: Size.square(widget.size),
              painter: _DialPainter(
                startMinutes: startMin,
                endMinutes: endMin,
                durationLabel: formatDialDuration(duration),
                faceColor: scheme.surfaceContainerHighest,
                trackColor: scheme.outlineVariant,
                rangeColor: scheme.primary,
                startColor: scheme.primary,
                endColor: scheme.error,
                tickColor: scheme.onSurfaceVariant,
                labelStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                durationStyle:
                    Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                activeHandle: _active,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${widget.start.format(context)} – ${widget.end.format(context)} · ${formatDialDuration(duration)}',
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ],
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  final int startMinutes;
  final int endMinutes;
  final String durationLabel;
  final Color faceColor;
  final Color trackColor;
  final Color rangeColor;
  final Color startColor;
  final Color endColor;
  final Color tickColor;
  final TextStyle? labelStyle;
  final TextStyle? durationStyle;
  final _DialHandle? activeHandle;

  _DialPainter({
    required this.startMinutes,
    required this.endMinutes,
    required this.durationLabel,
    required this.faceColor,
    required this.trackColor,
    required this.rangeColor,
    required this.startColor,
    required this.endColor,
    required this.tickColor,
    required this.labelStyle,
    required this.durationStyle,
    required this.activeHandle,
  });

  Offset _point(Offset center, double radius, int minutes) {
    final a = dialAngleForMinutes(minutes);
    return center + Offset(math.sin(a), -math.cos(a)) * radius;
  }

  void _drawLabel(
    Canvas canvas,
    Offset center,
    double radius,
    int minutes,
    String text,
  ) {
    final style = labelStyle;
    if (style == null || text.isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final pos = _point(center, radius, minutes) -
        Offset(painter.width / 2, painter.height / 2);
    painter.paint(canvas, pos);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    const handleR = 11.0;
    final radius = size.shortestSide / 2 - handleR - 2;
    if (radius <= 0) return;

    canvas.drawCircle(
      center,
      radius + handleR + 2,
      Paint()..color = faceColor,
    );

    final tickPaint = Paint()
      ..color = tickColor
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    for (var h = 0; h < 24; h++) {
      final inner = radius - (h % 6 == 0 ? 9 : 4.5);
      canvas.drawLine(
        _point(center, inner, h * 60),
        _point(center, radius, h * 60),
        tickPaint,
      );
    }
    _drawLabel(canvas, center, radius - 22, 0, '12a');
    _drawLabel(canvas, center, radius - 22, 360, '6a');
    _drawLabel(canvas, center, radius - 22, 720, '12p');
    _drawLabel(canvas, center, radius - 22, 1080, '6p');

    final sweep =
        clockwiseMinutes(startMinutes, endMinutes) / _dayMinutes * math.pi * 2;
    if (sweep > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        dialAngleForMinutes(startMinutes) - math.pi / 2,
        sweep,
        false,
        Paint()
          ..color = rangeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..strokeCap = StrokeCap.round,
      );
    } else {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = trackColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }

    _drawHandle(canvas, center, radius, startMinutes, startColor,
        active: activeHandle == _DialHandle.start);
    _drawHandle(canvas, center, radius, endMinutes, endColor,
        active: activeHandle == _DialHandle.end);

    final durationStyle = this.durationStyle;
    if (durationStyle != null) {
      final painter = TextPainter(
        text: TextSpan(text: durationLabel, style: durationStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: radius);
      painter.paint(
        canvas,
        center - Offset(painter.width / 2, painter.height / 2),
      );
    }
  }

  void _drawHandle(
    Canvas canvas,
    Offset center,
    double radius,
    int minutes,
    Color color, {
    required bool active,
  }) {
    final pos = _point(center, radius, minutes);
    const r = 11.0;
    canvas.drawCircle(
      pos,
      active ? r + 3 : r,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      pos,
      active ? r + 3 : r,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawCircle(pos, 3, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _DialPainter old) =>
      old.startMinutes != startMinutes ||
      old.endMinutes != endMinutes ||
      old.durationLabel != durationLabel ||
      old.faceColor != faceColor ||
      old.rangeColor != rangeColor ||
      old.activeHandle != activeHandle;
}
