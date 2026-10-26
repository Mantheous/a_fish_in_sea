import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Zoom limits for the goal graph. Small enough to fit a large tree, large
/// enough to read a card without switching to the editor.
const double kGraphMinScale = 0.12;
const double kGraphMaxScale = 2.5;

/// Pan/zoom transform for the goal graph. Pure math around a
/// [TransformationController], extracted from the viewport so the gesture
/// code only decides *what* changed, not how the matrix is built.
class NodeGraphCamera {
  final TransformationController controller = TransformationController();

  Size viewport = Size.zero;

  double get scale => controller.value.getMaxScaleOnAxis();

  Offset get translation {
    final t = controller.value.getTranslation();
    return Offset(t.x, t.y);
  }

  void fit(Size layoutSize) {
    if (viewport.isEmpty || layoutSize.isEmpty) return;
    final next = math
        .min(1.0, (viewport.width - 48) / layoutSize.width)
        .clamp(kGraphMinScale, kGraphMaxScale);
    final tx = (viewport.width - layoutSize.width * next) / 2;
    final scaledHeight = layoutSize.height * next;
    final ty = scaledHeight < viewport.height
        ? math.max(16.0, (viewport.height - scaledHeight) / 2)
        : 16.0;
    setTransform(next, Offset(tx, ty));
  }

  /// Pans minimally so [rect] is inside the viewport, keeping the current
  /// zoom. A card already in view does not move the canvas.
  void reveal(Rect rect) {
    if (viewport.isEmpty) return;
    final current = scale;
    final t = translation;
    const padding = 24.0;
    final left = rect.left * current + t.dx;
    final top = rect.top * current + t.dy;
    final right = rect.right * current + t.dx;
    final bottom = rect.bottom * current + t.dy;
    var dx = 0.0;
    var dy = 0.0;
    if (right > viewport.width - padding) {
      dx = viewport.width - padding - right;
    }
    if (left + dx < padding) dx = padding - left;
    if (bottom > viewport.height - padding) {
      dy = viewport.height - padding - bottom;
    }
    if (top + dy < padding) dy = padding - top;
    if (dx == 0 && dy == 0) return;
    setTransform(current, Offset(t.dx + dx, t.dy + dy));
  }

  void zoomBy(double factor) => zoomTo(scale * factor);

  void zoomTo(double target, {Offset? focal}) {
    if (viewport.isEmpty) return;
    final current = scale;
    final next = target.clamp(kGraphMinScale, kGraphMaxScale);
    if (next == current) return;
    final f = next / current;
    final center = focal ?? Offset(viewport.width / 2, viewport.height / 2);
    final t = translation;
    setTransform(
      next,
      Offset(
        center.dx - f * (center.dx - t.dx),
        center.dy - f * (center.dy - t.dy),
      ),
    );
  }

  void translateBy(Offset delta) {
    setTransform(scale, translation + delta);
  }

  /// Places [scenePoint] under [focal] at [nextScale]. Pinch and trackpad
  /// gestures both reduce to this.
  void scaleAround({
    required double nextScale,
    required Offset scenePoint,
    required Offset focal,
  }) {
    final next = nextScale.clamp(kGraphMinScale, kGraphMaxScale);
    setTransform(
      next,
      Offset(focal.dx - scenePoint.dx * next, focal.dy - scenePoint.dy * next),
    );
  }

  void setTransform(double scale, Offset translation) {
    controller.value = matrix(scale, translation.dx, translation.dy);
  }

  Offset toScene(Offset local) => sceneIn(controller.value, local);

  Offset sceneIn(Matrix4 matrix, Offset local) {
    try {
      return MatrixUtils.transformPoint(Matrix4.inverted(matrix), local);
    } catch (_) {
      return local;
    }
  }

  void dispose() => controller.dispose();
}

Matrix4 matrix(double scale, double tx, double ty) {
  final m = Matrix4.identity();
  m.setEntry(0, 0, scale);
  m.setEntry(1, 1, scale);
  m.setEntry(2, 2, scale);
  m.setEntry(0, 3, tx);
  m.setEntry(1, 3, ty);
  return m;
}
