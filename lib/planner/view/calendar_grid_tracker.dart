import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// The plan calendar's time-grid geometry: its scroll position and where
/// that grid sits on screen.
///
/// The Plan + Report view has exactly one calendar, so there is nothing to
/// keep in sync. The report overlay only *reads* this geometry: it moves
/// its chips with the grid's scroll offset and clips them to the grid's
/// viewport. Every gesture — scroll, swipe, tap, drag — is owned by the
/// plan calendar itself.
class PlanGridTracker extends ChangeNotifier {
  PlanGridTracker({
    required bool Function() isMounted,
    required double timeGridViewportThreshold,
    GlobalKey? anchorKey,
  }) : _isMounted = isMounted,
       _timeGridViewportThreshold = timeGridViewportThreshold,
       _anchorKey = anchorKey;

  final bool Function() _isMounted;
  final double _timeGridViewportThreshold;

  /// The widget the report overlay is laid out in (the calendar's Stack).
  /// Geometry is reported relative to it so the overlay can place lanes
  /// without measuring anything during its own layout.
  final GlobalKey? _anchorKey;
  ScrollableState? _state;
  ScrollPosition? _position;
  Rect? _viewportGlobal;
  Rect? _viewportLocal;
  bool _notifyScheduled = false;

  /// The time grid's scroll position, or null before the first discovery.
  ScrollPosition? get position => _position;

  /// Global rect of the time-grid viewport: the only place timed content
  /// paints. Null before the first discovery.
  Rect? get viewportGlobal => _viewportGlobal;

  /// The same viewport in the coordinate space of [_anchorKey]'s box — what
  /// the overlay positions its lanes against.
  Rect? get viewportLocal => _viewportLocal;

  /// Current scroll offset of the grid, in pixels.
  double get scrollOffset {
    final position = _position;
    return position != null && position.hasPixels ? position.pixels : 0;
  }

  /// Drops the tracked grid so the next [discover] picks up the one the new
  /// view built. Called when Day ↔ Week swaps the calendar's internals.
  void reset() {
    _position?.removeListener(_onScrollTick);
    _state = null;
    _position = null;
    _viewportGlobal = null;
    _viewportLocal = null;
  }

  /// Finds the time grid behind [root] (a context above the SfCalendar) and
  /// tracks it from now on.
  ///
  /// Syncfusion keeps its scroll controller private, and below ~a dozen
  /// widget layers there is no public hook into it. Walking the element
  /// tree once is the one discovery path that works even when a day has no
  /// timed appointments (the appointment builder is the other hook, and it
  /// only runs when there is something to build).
  ///
  /// Re-running is cheap and idempotent; callers do it after view or layout
  /// changes, because switching Day ↔ Week rebuilds the scrollable.
  void discover(BuildContext root) {
    // An appointment builder already hooked the real grid: keep it. Tree
    // order can't tell the visible view from the ones Syncfusion keeps
    // built for the other Day/Week/Month modes.
    final current = _position;
    if (current != null && current.hasPixels && _viewportGlobal != null) {
      return;
    }
    final found = _findTimeGrid(root);
    if (found == null) return;
    _capture(found.state);
  }

  /// Re-reads the grid's on-screen rect (its size changes with the window
  /// or the side panel, without the scrollable being recreated).
  void refreshViewport() {
    final state = _state;
    if (state == null) return;
    _captureRenderBox(state.context);
  }

  /// Hooks the tracker to the scrollable that owns [context]. Called from
  /// appointment builders, which run inside the calendar's own build.
  void rememberPosition(BuildContext context, {required bool timeGrid}) {
    if (!timeGrid) return;
    final scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) return;
    _capture(scrollable);
  }

  bool onPlanScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    final context = notification.context;
    if (context == null) return false;
    final scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) return false;
    if (!identical(scrollable.position, _position)) {
      if (!_isTimeGridPosition(scrollable.position)) return false;
      _capture(scrollable);
      return false;
    }
    notifyListeners();
    return false;
  }

  void onPlanPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final plan = _position;
    if (plan == null || !plan.hasPixels) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (signal) {
      if (!_isMounted() || !plan.hasPixels) return;
      plan.pointerScroll((signal as PointerScrollEvent).scrollDelta.dy);
    });
  }

  void onPlanVerticalDrag(DragUpdateDetails details) {
    final plan = _position;
    if (plan == null || !plan.hasPixels) return;
    final target = (plan.pixels - details.delta.dy).clamp(
      plan.minScrollExtent,
      plan.maxScrollExtent,
    );
    if ((plan.pixels - target).abs() < 0.5) return;
    plan.jumpTo(target);
  }

  bool _isTimeGridPosition(ScrollPosition position) {
    if (!position.hasPixels) return false;
    // The all-day row is a small horizontal scrollable; the time grid is
    // the tall vertical one.
    return position.axis == Axis.vertical &&
        position.viewportDimension > _timeGridViewportThreshold;
  }

  _FoundScrollable? _findTimeGrid(BuildContext root) {
    ScrollableState? best;
    void visit(Element element) {
      if (element.widget is Scrollable) {
        final state = (element as StatefulElement).state as ScrollableState;
        final position = state.position;
        if (_isTimeGridPosition(position) &&
            (best == null ||
                position.viewportDimension >
                    best!.position.viewportDimension)) {
          best = state;
        }
        // A grid's own scrollables can't contain another one.
        return;
      }
      element.visitChildElements(visit);
    }

    void visitChildOrSelf(Element element) {
      if (element.widget is Scrollable) {
        visit(element);
        return;
      }
      element.visitChildElements(visitChildOrSelf);
    }

    visitChildOrSelf(root as Element);
    final found = best;
    return found == null ? null : _FoundScrollable(found);
  }

  void _capture(ScrollableState state) {
    final position = state.position;
    if (!identical(_position, position)) {
      _position?.removeListener(_onScrollTick);
      _state = state;
      _position = position;
      position.addListener(_onScrollTick);
    } else {
      _state = state;
    }
    _captureRenderBox(state.context);
    _notify();
  }

  void _captureRenderBox(BuildContext scrollableContext) {
    final render = scrollableContext.findRenderObject();
    if (render is! RenderBox || !render.hasSize) return;
    final rect = render.localToGlobal(Offset.zero) & render.size;
    final anchor = _anchorKey?.currentContext?.findRenderObject();
    final Rect? local;
    if (anchor is RenderBox && anchor.hasSize) {
      local = rect.shift(-anchor.localToGlobal(Offset.zero));
    } else {
      local = null;
    }
    if (_viewportGlobal == rect && _viewportLocal == local) return;
    _viewportGlobal = rect;
    _viewportLocal = local;
    _notify();
  }

  void _onScrollTick() => _notify();

  /// Appointment builders and tree walks can run during the calendar's
  /// build, where notifying synchronously would setState a listener
  /// mid-build. Defer only then; scroll ticks notify immediately so chips
  /// track the grid without a frame of lag.
  void _notify() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_notifyScheduled) return;
      _notifyScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _notifyScheduled = false;
        notifyListeners();
      });
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _position?.removeListener(_onScrollTick);
    super.dispose();
  }
}

class _FoundScrollable {
  const _FoundScrollable(this.state);

  final ScrollableState state;
}
