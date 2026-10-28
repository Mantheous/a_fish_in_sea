import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Makes a plan tile draggable with the pointer that is actually in use.
///
/// The calendar's own drag-and-drop only starts after a long press, which
/// makes a desktop mouse drag scroll the time grid instead of moving the
/// tile. This wrapper adds a mouse/stylus drag that starts as soon as the
/// pointer moves past the normal hit slop, while touch keeps the calendar's
/// scroll gesture and still starts a drag only after a long press.
///
/// Both paths report global pointer positions; the owner converts them into
/// a drop time so it can also compensate for the grid auto-scrolling under
/// the pointer.
class PlanTileDragArea extends StatefulWidget {
  const PlanTileDragArea({
    super.key,
    required this.child,
    this.enabled = true,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDragCancel,
    this.onPointerSignal,
  });

  final Widget child;

  /// False leaves the tile exactly as it was: the calendar scrolls as usual.
  final bool enabled;

  final ValueChanged<Offset>? onDragStart;
  final ValueChanged<Offset>? onDragUpdate;
  final VoidCallback? onDragEnd;
  final VoidCallback? onDragCancel;

  /// Wheel/trackpad scrolling over this tile. Tiles drawn in the Plan +
  /// Report overlay sit outside the calendar's scrollable, so they forward
  /// the signal themselves.
  final ValueChanged<PointerSignalEvent>? onPointerSignal;

  @override
  State<PlanTileDragArea> createState() => _PlanTileDragAreaState();
}

class _PlanTileDragAreaState extends State<PlanTileDragArea> {
  bool _dragging = false;

  void _start(Offset globalPosition) {
    if (_dragging) return;
    _dragging = true;
    widget.onDragStart?.call(globalPosition);
  }

  void _update(Offset globalPosition) {
    if (!_dragging) return;
    widget.onDragUpdate?.call(globalPosition);
  }

  void _finish() {
    if (!_dragging) return;
    _dragging = false;
    widget.onDragEnd?.call();
  }

  void _cancel() {
    if (!_dragging) return;
    _dragging = false;
    widget.onDragCancel?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return MouseRegion(
      cursor: _dragging ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
      child: Listener(
        onPointerSignal: widget.onPointerSignal,
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: <Type, GestureRecognizerFactory>{
            _ImmediatePlanDragRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  _ImmediatePlanDragRecognizer
                >(
                  () => _ImmediatePlanDragRecognizer(
                    supportedDevices: const {
                      PointerDeviceKind.mouse,
                      PointerDeviceKind.trackpad,
                      PointerDeviceKind.stylus,
                      PointerDeviceKind.invertedStylus,
                      PointerDeviceKind.unknown,
                    },
                    // Count the movement that crossed the slop toward the
                    // drop instead of discarding it: a short flick must
                    // still move the tile.
                  )..dragStartBehavior = DragStartBehavior.down,
                  (recognizer) {
                    recognizer.onStart = (details) =>
                        _start(details.globalPosition);
                    recognizer.onUpdate = (details) =>
                        _update(details.globalPosition);
                    recognizer.onEnd = (_) => _finish();
                    recognizer.onCancel = _cancel;
                  },
                ),
            LongPressGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  LongPressGestureRecognizer
                >(
                  () => LongPressGestureRecognizer(
                    supportedDevices: const {PointerDeviceKind.touch},
                  ),
                  (recognizer) {
                    // Once the long press is accepted the pointer may move
                    // freely (postAcceptSlopTolerance defaults to null).
                    recognizer.onLongPressStart = (details) =>
                        _start(details.globalPosition);
                    recognizer.onLongPressMoveUpdate = (details) =>
                        _update(details.globalPosition);
                    recognizer.onLongPressEnd = (_) => _finish();
                    recognizer.onLongPressCancel = _cancel;
                  },
                ),
          },
          child: widget.child,
        ),
      ),
    );
  }
}

/// A pan drag that accepts at the pointer hit slop instead of the (larger)
/// pan slop. The calendar scrollable's vertical drag accepts at the same
/// threshold, and this recognizer sits closer to the pointer, so it wins
/// the arena and the tile moves instead of the grid scrolling.
class _ImmediatePlanDragRecognizer extends PanGestureRecognizer {
  _ImmediatePlanDragRecognizer({super.supportedDevices});

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    return globalDistanceMoved.abs() >
        computeHitSlop(pointerDeviceKind, gestureSettings);
  }
}
