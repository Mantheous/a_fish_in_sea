import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../service/node_graph_layout.dart';

/// Pan/zoom surface matching the original goal graph: the canvas pans on a
/// drag, the mouse wheel/pinch zooms, and the floating pill offers zoom
/// out/in and fit-to-screen.
///
/// Multi-select is an explicit tool toggled from the pill. While it is on,
/// panning is disabled so dragging empty canvas draws a marquee and selects
/// the cards it touches; tapping cards toggles membership. Turning the tool
/// off returns the graph to its original pan-first behavior.
class NodeGraphViewport extends StatefulWidget {
  const NodeGraphViewport({
    super.key,
    required this.layoutSize,
    required this.placements,
    required this.child,
    this.fitToken = 0,
    this.revealRect,
    this.revealToken = 0,
    this.multiSelect = false,
    this.onToggleMultiSelect,
    this.onMarqueeStart,
    this.onMarqueeChanged,
    this.onMarqueeEnd,
  });

  final Size layoutSize;
  final Widget child;
  final int fitToken;

  /// Cards that marquee selection can hit. Compact path markers are not
  /// selectable: they are filter context, not members of the result.
  final List<GraphNodePlacement> placements;

  /// Canvas-space rect to bring into view when [revealToken] changes.
  final Rect? revealRect;
  final int revealToken;

  /// True while the multi-select tool is active.
  final bool multiSelect;
  final VoidCallback? onToggleMultiSelect;

  /// A marquee started on empty canvas (multi-select tool only).
  final VoidCallback? onMarqueeStart;

  /// Live ids touched by the current marquee.
  final ValueChanged<Set<String>>? onMarqueeChanged;

  /// The marquee gesture ended (released or cancelled).
  final VoidCallback? onMarqueeEnd;

  @override
  State<NodeGraphViewport> createState() => _NodeGraphViewportState();
}

class _NodeGraphViewportState extends State<NodeGraphViewport> {
  static const double _minScale = 0.12;
  static const double _maxScale = 2.5;

  final TransformationController _controller = TransformationController();
  Size _viewport = Size.zero;
  bool _didFit = false;
  bool _fitScheduled = false;
  bool _revealScheduled = false;

  final Set<int> _pointers = {};
  int? _marqueePointer;
  Offset? _marqueeStart;
  Offset? _marqueeStartScene;
  Offset? _marqueeCurrent;
  Set<String> _marqueeIds = const {};

  @override
  void didUpdateWidget(covariant NodeGraphViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fitToken != oldWidget.fitToken) {
      _didFit = false;
      _scheduleFit();
    } else if (widget.revealToken != oldWidget.revealToken) {
      _scheduleReveal();
    }
    if (oldWidget.multiSelect && !widget.multiSelect) {
      // Turning the tool off stops an in-flight marquee without calling
      // setState during didUpdateWidget; the rebuild is already coming.
      _pointers.clear();
      _marqueePointer = null;
      _marqueeStart = null;
      _marqueeStartScene = null;
      _marqueeCurrent = null;
      _marqueeIds = const {};
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scheduleFit() {
    if (_fitScheduled) return;
    _fitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fitScheduled = false;
      if (!mounted) return;
      _didFit = true;
      _fit();
    });
  }

  /// Pans minimally so [NodeGraphViewport.revealRect] is inside the viewport,
  /// keeping the user's zoom. A card already in view does not move the canvas.
  void _scheduleReveal() {
    if (_revealScheduled) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted) return;
      _reveal();
    });
  }

  void _reveal() {
    final rect = widget.revealRect;
    if (rect == null || _viewport.isEmpty) return;
    final m = _controller.value;
    final scale = m.getMaxScaleOnAxis();
    final t = m.getTranslation();
    const padding = 24.0;
    final left = rect.left * scale + t.x;
    final top = rect.top * scale + t.y;
    final right = rect.right * scale + t.x;
    final bottom = rect.bottom * scale + t.y;
    var dx = 0.0;
    var dy = 0.0;
    if (right > _viewport.width - padding) {
      dx = _viewport.width - padding - right;
    }
    if (left + dx < padding) dx = padding - left;
    if (bottom > _viewport.height - padding) {
      dy = _viewport.height - padding - bottom;
    }
    if (top + dy < padding) dy = padding - top;
    if (dx == 0 && dy == 0) return;
    _controller.value = _matrix(scale, t.x + dx, t.y + dy);
  }

  Matrix4 _matrix(double scale, double tx, double ty) {
    final m = Matrix4.identity();
    m.setEntry(0, 0, scale);
    m.setEntry(1, 1, scale);
    m.setEntry(2, 2, scale);
    m.setEntry(0, 3, tx);
    m.setEntry(1, 3, ty);
    return m;
  }

  void _fit() {
    if (_viewport.isEmpty || widget.layoutSize.isEmpty) return;
    final scale = math
        .min(1.0, (_viewport.width - 48) / widget.layoutSize.width)
        .clamp(_minScale, _maxScale);
    final tx = (_viewport.width - widget.layoutSize.width * scale) / 2;
    final scaledHeight = widget.layoutSize.height * scale;
    final ty = scaledHeight < _viewport.height
        ? math.max(16.0, (_viewport.height - scaledHeight) / 2)
        : 16.0;
    _controller.value = _matrix(scale, tx, ty);
  }

  void _zoomBy(double factor) {
    if (_viewport.isEmpty) return;
    final m = _controller.value;
    final scale = m.getMaxScaleOnAxis();
    final next = (scale * factor).clamp(_minScale, _maxScale);
    if (next == scale) return;
    final f = next / scale;
    final center = Offset(_viewport.width / 2, _viewport.height / 2);
    final t = m.getTranslation();
    final tx = center.dx - f * (center.dx - t.x);
    final ty = center.dy - f * (center.dy - t.y);
    _controller.value = _matrix(next, tx, ty);
  }

  Offset _toScene(Offset local) {
    try {
      return MatrixUtils.transformPoint(
        Matrix4.inverted(_controller.value),
        local,
      );
    } catch (_) {
      return local;
    }
  }

  bool _hitsCard(Offset scene) {
    for (final placement in widget.placements) {
      if (placement.rect.contains(scene)) return true;
    }
    return false;
  }

  Set<String> _idsIn(Rect sceneRect) {
    return {
      for (final placement in widget.placements)
        if (!placement.compact && sceneRect.overlaps(placement.rect))
          placement.node.id,
    };
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (!widget.multiSelect) return;
    _pointers.add(event.pointer);
    if (_pointers.length > 1) {
      _cancelMarquee();
      return;
    }
    if (event.kind == PointerDeviceKind.mouse &&
        event.buttons != kPrimaryMouseButton) {
      return;
    }
    if (_hitsCard(_toScene(event.localPosition))) return;
    _marqueePointer = event.pointer;
    _marqueeStart = event.localPosition;
    _marqueeStartScene = _toScene(event.localPosition);
    _marqueeCurrent = event.localPosition;
    _marqueeIds = const {};
    setState(() {});
    widget.onMarqueeStart?.call();
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!widget.multiSelect || event.pointer != _marqueePointer) return;
    final start = _marqueeStartScene;
    if (start == null) return;
    _marqueeCurrent = event.localPosition;
    // The marquee is drawn in screen space but cards live in layout space.
    // Convert both corners through the transform before comparing, otherwise
    // a fitted/zoomed graph selects cards elsewhere in the tree.
    final rect = Rect.fromPoints(start, _toScene(event.localPosition));
    final ids = _idsIn(rect);
    if (!setEquals(ids, _marqueeIds)) {
      _marqueeIds = ids;
      widget.onMarqueeChanged?.call(Set.unmodifiable(ids));
    }
    setState(() {});
  }

  void _handlePointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (event.pointer == _marqueePointer) _cancelMarquee();
  }

  void _cancelMarquee() {
    final active = _marqueeStart != null;
    _marqueePointer = null;
    if (active) {
      setState(() {
        _marqueeStart = null;
        _marqueeStartScene = null;
        _marqueeCurrent = null;
        _marqueeIds = const {};
      });
      widget.onMarqueeEnd?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = Size(constraints.maxWidth, constraints.maxHeight);
        if (!_didFit && !_fitScheduled) {
          _scheduleFit();
        }
        return Stack(
          children: [
            Positioned.fill(
              child: Listener(
                onPointerDown: _handlePointerDown,
                onPointerMove: _handlePointerMove,
                onPointerUp: _handlePointerUp,
                onPointerCancel: _handlePointerUp,
                child: InteractiveViewer(
                  transformationController: _controller,
                  constrained: false,
                  boundaryMargin: const EdgeInsets.all(600),
                  minScale: _minScale,
                  maxScale: _maxScale,
                  panEnabled: !widget.multiSelect,
                  child: SizedBox(
                    width: widget.layoutSize.width,
                    height: widget.layoutSize.height,
                    child: widget.child,
                  ),
                ),
              ),
            ),
            if (_marqueeStart != null && _marqueeCurrent != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _MarqueePainter(
                      rect: Rect.fromPoints(_marqueeStart!, _marqueeCurrent!),
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
            Positioned(
              right: 12,
              top: 10,
              child: Material(
                elevation: 1,
                borderRadius: BorderRadius.circular(24),
                color: scheme.surfaceContainerHigh.withValues(alpha: 0.94),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: const ValueKey('graph-multi-select-toggle'),
                      tooltip: widget.multiSelect
                          ? 'Exit multi-select'
                          : 'Select multiple goals',
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      style: IconButton.styleFrom(
                        backgroundColor: widget.multiSelect
                            ? scheme.primaryContainer
                            : null,
                      ),
                      onPressed: widget.onToggleMultiSelect,
                      icon: const Icon(Icons.checklist),
                    ),
                    IconButton(
                      tooltip: 'Zoom out',
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      onPressed: () => _zoomBy(0.8),
                      icon: const Icon(Icons.remove),
                    ),
                    IconButton(
                      tooltip: 'Zoom in',
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      onPressed: () => _zoomBy(1.25),
                      icon: const Icon(Icons.add),
                    ),
                    IconButton(
                      tooltip: 'Fit to screen',
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      onPressed: _fit,
                      icon: const Icon(Icons.fit_screen_outlined),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MarqueePainter extends CustomPainter {
  const _MarqueePainter({required this.rect, required this.color});

  final Rect rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.08));
    canvas.drawRect(
      rect,
      Paint()
        ..color = color.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _MarqueePainter oldDelegate) =>
      oldDelegate.rect != rect || oldDelegate.color != color;
}
