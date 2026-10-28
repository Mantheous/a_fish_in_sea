import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../service/node_graph_layout.dart';
import 'node_graph_camera.dart';
import 'node_graph_nav_controls.dart';

/// Figma-style pan/zoom surface for the goal graph.
///
/// Pan is the default tool: a drag moves the graph, while tapping a card
/// still selects it, so single-goal editing keeps working without switching
/// tools. The Select tool (pill button or V) turns empty-canvas drags into a
/// marquee that selects every card it touches (shift/ctrl/cmd adds to the
/// current selection). Hold space for a temporary pan, use a middle-mouse
/// drag, or two-finger scroll; trackpads can pinch to zoom. Ctrl/cmd + wheel
/// zooms around the cursor. The floating pill carries explicit Select/Pan
/// buttons, zoom controls, a percentage menu, and fit-to-screen, mirroring
/// the controls in Figma.
class NodeGraphViewport extends StatefulWidget {
  const NodeGraphViewport({
    super.key,
    required this.layoutSize,
    required this.placements,
    required this.child,
    this.fitToken = 0,
    this.revealRect,
    this.revealToken = 0,
    this.onMarqueeStart,
    this.onMarqueeChanged,
    this.onMarqueeEnd,
    this.onSelectAll,
    this.onClearSelection,
  });

  final Size layoutSize;
  final Widget child;
  final int fitToken;

  /// Cards that marquee selection can hit. Compact path markers are not
  /// selectable in bulk: they are filter context, not members of the result.
  final List<GraphNodePlacement> placements;

  /// Canvas-space rect to bring into view when [revealToken] changes.
  final Rect? revealRect;
  final int revealToken;

  /// A marquee gesture started on empty canvas. [additive] is true when
  /// shift/ctrl/cmd was held, in which case the caller keeps the previous
  /// selection as the base.
  final ValueChanged<bool>? onMarqueeStart;

  /// Live ids touched by the current marquee. Called only when the set
  /// changes, so a drag does not rebuild the graph every pixel.
  final ValueChanged<Set<String>>? onMarqueeChanged;

  /// The marquee gesture ended (released or cancelled).
  final VoidCallback? onMarqueeEnd;

  final VoidCallback? onSelectAll;
  final VoidCallback? onClearSelection;

  @override
  State<NodeGraphViewport> createState() => _NodeGraphViewportState();
}

const double _wheelScaleFactor = 200;

class _NodeGraphViewportState extends State<NodeGraphViewport> {
  final NodeGraphCamera _camera = NodeGraphCamera();
  final FocusNode _focusNode = FocusNode(debugLabel: 'goal-graph');

  bool _didFit = false;
  bool _userMovedCamera = false;
  bool _fitScheduled = false;
  bool _revealScheduled = false;
  int _zoomPercent = 100;

  /// Pan is the default: a drag moves the graph, while a tap still selects
  /// the card under the pointer. The Select tool (pill button or V) switches
  /// empty-canvas drags to marquee selection.
  bool _handTool = true;
  bool _spaceHeld = false;

  final Map<int, Offset> _pointers = {};
  _Gesture _gesture = _Gesture.none;
  int? _activePointer;

  Offset? _panStart;
  Offset _panStartTranslation = Offset.zero;

  Offset? _marqueeStart;
  Offset? _marqueeStartScene;
  Offset? _marqueeCurrent;
  Set<String> _marqueeIds = const {};

  Matrix4? _pinchStart;
  double _pinchStartScale = 1;
  Offset _pinchStartFocal = Offset.zero;
  double _pinchStartDistance = 0;

  Matrix4? _trackpadStart;
  Offset _trackpadFocal = Offset.zero;
  double _trackpadScale = 1;

  bool get _panMode => _handTool || _spaceHeld;

  bool get _additivePressed =>
      HardwareKeyboard.instance.isShiftPressed ||
      HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isMetaPressed;

  @override
  void initState() {
    super.initState();
    _camera.controller.addListener(_handleTransformChanged);
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
  }

  @override
  void didUpdateWidget(covariant NodeGraphViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fitToken != oldWidget.fitToken) {
      // An explicit refit (filter change) resets the view for the new graph.
      _didFit = false;
      _userMovedCamera = false;
      _scheduleFit();
    } else if (widget.revealToken != oldWidget.revealToken) {
      _userMovedCamera = true;
      _scheduleReveal();
    } else if (widget.layoutSize != oldWidget.layoutSize && !_userMovedCamera) {
      // Nodes can arrive after the first fit (demo hydration, the homework
      // structure post-frame, generated instances). Keep the initial view
      // fitted until the user actually pans or zooms.
      _scheduleFit();
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    _camera.controller.removeListener(_handleTransformChanged);
    _camera.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleTransformChanged() {
    final percent = (_camera.scale * 100).round();
    if (percent != _zoomPercent && mounted) {
      setState(() => _zoomPercent = percent);
    }
  }

  bool _handleGlobalKey(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.space) return false;
    final down = event is KeyDownEvent;
    final up = event is KeyUpEvent;
    if (!down && !up) return false;
    if (down == _spaceHeld) return false;
    if (mounted) setState(() => _spaceHeld = down);
    // Never consume space: it still belongs to buttons and text fields.
    return false;
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final ctrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (event.logicalKey == LogicalKeyboardKey.keyA && ctrl) {
      widget.onSelectAll?.call();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _cancelMarquee();
      widget.onClearSelection?.call();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyH) {
      setState(() => _handTool = true);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyV) {
      setState(() => _handTool = false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _scheduleFit() {
    if (_fitScheduled) return;
    _fitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fitScheduled = false;
      if (!mounted) return;
      _didFit = true;
      _camera.fit(widget.layoutSize);
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
      final rect = widget.revealRect;
      if (rect != null) _camera.reveal(rect);
    });
  }

  void _handlePointerDown(PointerDownEvent event) {
    _focusNode.requestFocus();
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length >= 2) {
      _userMovedCamera = true;
      _endGesture();
      _gesture = _Gesture.pinch;
      _pinchStart = _camera.controller.value.clone();
      _pinchStartScale = _camera.scale;
      _pinchStartFocal = _midpoint();
      _pinchStartDistance = _distance();
      return;
    }
    if (_panRequested(event)) {
      _gesture = _Gesture.pan;
      _activePointer = event.pointer;
      _panStart = event.localPosition;
      _panStartTranslation = _camera.translation;
      return;
    }
    if (event.kind == PointerDeviceKind.mouse &&
        event.buttons != kPrimaryMouseButton) {
      return;
    }
    if (_hitsCard(_camera.toScene(event.localPosition))) return;
    _gesture = _Gesture.marquee;
    _activePointer = event.pointer;
    _marqueeStart = event.localPosition;
    _marqueeStartScene = _camera.toScene(event.localPosition);
    _marqueeCurrent = event.localPosition;
    _marqueeIds = const {};
    setState(() {});
    widget.onMarqueeStart?.call(_additivePressed);
  }

  bool _panRequested(PointerDownEvent event) {
    final pan = _panMode || (event.buttons & kMiddleMouseButton) != 0;
    if (pan) _userMovedCamera = true;
    return pan;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    switch (_gesture) {
      case _Gesture.pinch:
        _updatePinch();
      case _Gesture.pan:
        if (event.pointer != _activePointer || _panStart == null) return;
        final delta = event.localPosition - _panStart!;
        _camera.setTransform(
          _camera.scale,
          Offset(
            _panStartTranslation.dx + delta.dx,
            _panStartTranslation.dy + delta.dy,
          ),
        );
      case _Gesture.marquee:
        if (event.pointer != _activePointer || _marqueeStart == null) return;
        _marqueeCurrent = event.localPosition;
        // The marquee is drawn in screen space but cards live in layout
        // space. Convert both corners through the camera before comparing,
        // otherwise a fit/zoomed graph selects whatever happens to sit at
        // those raw coordinates in the unscaled layout.
        final start = _marqueeStartScene;
        if (start == null) return;
        final rect = Rect.fromPoints(start, _camera.toScene(_marqueeCurrent!));
        final ids = _idsIn(rect);
        if (!setEquals(ids, _marqueeIds)) {
          _marqueeIds = ids;
          widget.onMarqueeChanged?.call(Set.unmodifiable(ids));
        }
        setState(() {});
      case _Gesture.none:
        break;
    }
  }

  void _handlePointerUp(PointerEvent event) {
    final hadPointer = _pointers.remove(event.pointer) != null;
    if (!hadPointer) return;
    if (_gesture == _Gesture.pinch) {
      if (_pointers.length < 2) {
        _gesture = _Gesture.none;
        _pinchStart = null;
      }
      return;
    }
    if (event.pointer != _activePointer) return;
    if (_gesture == _Gesture.marquee) _cancelMarquee();
    _gesture = _Gesture.none;
    _activePointer = null;
    _panStart = null;
  }

  void _endGesture() {
    if (_gesture == _Gesture.marquee) _cancelMarquee();
    _gesture = _Gesture.none;
    _activePointer = null;
    _panStart = null;
    _pinchStart = null;
  }

  void _cancelMarquee() {
    final active = _marqueeStart != null;
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

  Offset _midpoint() {
    final points = _pointers.values.toList(growable: false);
    if (points.length < 2) return Offset.zero;
    return (points[0] + points[1]) / 2;
  }

  double _distance() {
    final points = _pointers.values.toList(growable: false);
    if (points.length < 2) return 0;
    return (points[0] - points[1]).distance;
  }

  void _updatePinch() {
    final start = _pinchStart;
    if (start == null || _pointers.length < 2 || _pinchStartDistance == 0) {
      return;
    }
    final distance = _distance();
    if (distance == 0) return;
    final scale = (_pinchStartScale * distance / _pinchStartDistance).clamp(
      kGraphMinScale,
      kGraphMaxScale,
    );
    final scene = _camera.sceneIn(start, _pinchStartFocal);
    _camera.scaleAround(
      nextScale: scale,
      scenePoint: scene,
      focal: _midpoint(),
    );
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

  void _handlePointerSignal(PointerSignalEvent event) {
    _userMovedCamera = true;
    if (event is PointerScrollEvent) {
      final zoom =
          HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed;
      if (zoom) {
        _camera.zoomTo(
          _camera.scale * math.exp(-event.scrollDelta.dy / _wheelScaleFactor),
          focal: event.localPosition,
        );
        return;
      }
      var delta = event.scrollDelta;
      // Shift+wheel is the horizontal pan on a mouse; trackpads already
      // send both axes.
      if (HardwareKeyboard.instance.isShiftPressed && delta.dx == 0) {
        delta = Offset(delta.dy, 0);
      }
      _camera.translateBy(-delta);
      return;
    }
    if (event is PointerScaleEvent) {
      _camera.zoomTo(_camera.scale * event.scale, focal: event.localPosition);
    }
  }

  void _handleTrackpadStart(PointerPanZoomStartEvent event) {
    _userMovedCamera = true;
    _trackpadStart = _camera.controller.value.clone();
    _trackpadFocal = event.localPosition;
    _trackpadScale = _camera.scale;
  }

  void _handleTrackpadUpdate(PointerPanZoomUpdateEvent event) {
    final start = _trackpadStart;
    if (start == null) return;
    final scale = (_trackpadScale * event.scale).clamp(
      kGraphMinScale,
      kGraphMaxScale,
    );
    final scene = _camera.sceneIn(start, _trackpadFocal);
    _camera.scaleAround(
      nextScale: scale,
      scenePoint: scene,
      focal: _trackpadFocal + event.localPan,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _camera.viewport = Size(constraints.maxWidth, constraints.maxHeight);
        if (!_didFit && !_fitScheduled) _scheduleFit();
        final scheme = Theme.of(context).colorScheme;
        return Focus(
          focusNode: _focusNode,
          onKeyEvent: _handleKey,
          child: Stack(
            children: [
              Positioned.fill(
                child: MouseRegion(
                  cursor: _panMode
                      ? (_gesture == _Gesture.pan
                            ? SystemMouseCursors.grabbing
                            : SystemMouseCursors.grab)
                      : SystemMouseCursors.basic,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _handlePointerDown,
                    onPointerMove: _handlePointerMove,
                    onPointerUp: _handlePointerUp,
                    onPointerCancel: _handlePointerUp,
                    onPointerSignal: _handlePointerSignal,
                    onPointerPanZoomStart: _handleTrackpadStart,
                    onPointerPanZoomUpdate: _handleTrackpadUpdate,
                    onPointerPanZoomEnd: (_) => _trackpadStart = null,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ClipRect(
                            child: AnimatedBuilder(
                              animation: _camera.controller,
                              child: AbsorbPointer(
                                absorbing: _spaceHeld,
                                child: SizedBox(
                                  width: widget.layoutSize.width,
                                  height: widget.layoutSize.height,
                                  child: widget.child,
                                ),
                              ),
                              builder: (context, child) => Transform(
                                transform: _camera.controller.value,
                                alignment: Alignment.topLeft,
                                child: child,
                              ),
                            ),
                          ),
                        ),
                        if (_marqueeStart != null && _marqueeCurrent != null)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: _MarqueePainter(
                                  rect: Rect.fromPoints(
                                    _marqueeStart!,
                                    _marqueeCurrent!,
                                  ),
                                  color: scheme.primary,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              // Outside the Listener: zooming and switching tools must not
              // start a marquee or clear the selection.
              Positioned(
                right: 12,
                top: 10,
                child: NodeGraphNavControls(
                  zoomPercent: _zoomPercent,
                  handTool: _handTool,
                  onSelectTool: () => setState(() => _handTool = false),
                  onPanTool: () => setState(() => _handTool = true),
                  onZoomOut: () {
                    _userMovedCamera = true;
                    _camera.zoomBy(0.8);
                  },
                  onZoomIn: () {
                    _userMovedCamera = true;
                    _camera.zoomBy(1.25);
                  },
                  onZoomTo: (target) {
                    _userMovedCamera = true;
                    _camera.zoomTo(target);
                  },
                  onFit: () {
                    _userMovedCamera = true;
                    _camera.fit(widget.layoutSize);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

enum _Gesture { none, pan, marquee, pinch }

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
