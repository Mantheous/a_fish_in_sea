import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  double? _contentHeight;
  Drag? _forwardedDrag;

  /// Notifies only when the time grid's on-screen rect changes — a window
  /// resize, the side panel opening, or Day ↔ Week swapping the grid.
  ///
  /// Scroll ticks deliberately do *not* notify these: the viewport is fixed
  /// while the content scrolls under it, so anything that only positions
  /// against the viewport (the plan-tile overlays and the report lane clip)
  /// can skip the whole scroll path. Rebuilding those on every tick was a
  /// measurable share of frame time.
  final ValueNotifier<Rect?> viewportGlobalListenable = ValueNotifier(null);
  final ValueNotifier<Rect?> viewportLocalListenable = ValueNotifier(null);

  /// Measured content height, including the part outside the viewport.
  final ValueNotifier<double?> contentHeightListenable = ValueNotifier(null);

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
    onPlanVerticalDragCancel();
    _position?.removeListener(_onScrollTick);
    _contentHeight = null;
    contentHeightListenable.value = null;
    _state = null;
    _position = null;
    _viewportGlobal = null;
    _viewportLocal = null;
    viewportGlobalListenable.value = null;
    viewportLocalListenable.value = null;
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
    if (current != null &&
        current.hasPixels &&
        _viewportGlobal != null &&
        _state!.mounted &&
        _overlapsAnchor(_state!.context)) {
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
    // Keep the grid we already track while it still sits in the calendar:
    // SfCalendar builds every neighbouring day page too, and during a pager
    // frame they can transiently report the visible rect. Re-adopting the
    // last builder would bind the tracker (and the report lanes) to an
    // off-screen page.
    final current = _state;
    if (current != null &&
        current.mounted &&
        _overlapsAnchor(current.context)) {
      return;
    }
    final scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) return;
    // Only adopt a grid that actually sits in the calendar we draw.
    if (!_overlapsAnchor(scrollable.context)) return;
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
      // SfCalendar syncs the scroll offset of the neighbouring day pages;
      // their notifications must not steal the grid (and with it the report
      // lanes) away from the page the user is looking at.
      final current = _state;
      if (current != null &&
          current.mounted &&
          current.position.hasPixels &&
          _overlapsAnchor(current.context)) {
        return false;
      }
      if (!_overlapsAnchor(scrollable.context)) return false;
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

  void onPlanVerticalDragStart(DragStartDetails details) {
    onPlanVerticalDragCancel();
    _forwardedDrag = _position?.drag(details, () => _forwardedDrag = null);
  }

  void onPlanVerticalDrag(DragUpdateDetails details) {
    _forwardedDrag?.update(details);
  }

  void onPlanVerticalDragEnd(DragEndDetails details) {
    _forwardedDrag?.end(details);
    _forwardedDrag = null;
  }

  void onPlanVerticalDragCancel() {
    _forwardedDrag?.cancel();
    _forwardedDrag = null;
  }

  bool _isTimeGridPosition(ScrollPosition position) {
    if (!position.hasPixels) return false;
    // The all-day row is a small horizontal scrollable; the time grid is
    // the tall vertical one.
    return position.axis == Axis.vertical &&
        position.viewportDimension > _timeGridViewportThreshold;
  }

  /// True when the box behind [scrollableContext] shares screen space with
  /// the calendar stack this tracker draws in. Off-screen carousel pages
  /// fail this: they are laid out a full viewport to the side.
  bool _overlapsAnchor(BuildContext scrollableContext) {
    final anchorContext = _anchorKey?.currentContext;
    if (anchorContext == null) return true;
    final box = scrollableContext.findRenderObject();
    final anchor = anchorContext.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return true;
    if (anchor is! RenderBox || !anchor.hasSize) return true;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final bounds = anchor.localToGlobal(Offset.zero) & anchor.size;
    // The visible page's grid is centered in the calendar. A neighbouring
    // page only touches an edge (or is mid-repositioning) — intersection
    // alone would let it steal the tracker.
    return bounds.contains(rect.center);
  }

  _FoundScrollable? _findTimeGrid(BuildContext root) {
    ScrollableState? best;
    ScrollableState? bestVisible;
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
        if (_isTimeGridPosition(position) &&
            _overlapsAnchor(element) &&
            (bestVisible == null ||
                position.viewportDimension >
                    bestVisible!.position.viewportDimension)) {
          bestVisible = state;
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
    final found = bestVisible ?? best;
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
    final previousHeight = _contentHeight;
    // The grid is a ListView. Its sliver reports the actual content height
    // even when a short hour range fits entirely inside the viewport.
    void measure(RenderObject object) {
      if (object is RenderSliver && object.geometry != null) {
        _contentHeight = object.geometry!.scrollExtent;
      } else {
        object.visitChildren(measure);
      }
    }

    measure(render);
    final rect = render.localToGlobal(Offset.zero) & render.size;
    final anchor = _anchorKey?.currentContext?.findRenderObject();
    final Rect? local;
    if (anchor is RenderBox && anchor.hasSize) {
      local = rect.shift(-anchor.localToGlobal(Offset.zero));
    } else {
      local = null;
    }
    if (_viewportGlobal == rect &&
        _viewportLocal == local &&
        previousHeight == _contentHeight)
      return;
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
    void publish() {
      final position = _position;
      contentHeightListenable.value =
          _contentHeight ??
          (position != null && position.hasContentDimensions
              ? position.maxScrollExtent -
                    position.minScrollExtent +
                    position.viewportDimension
              : null);
      // Viewport listeners only hear about real geometry changes: they are
      // the resize path, not the scroll path.
      if (viewportGlobalListenable.value != _viewportGlobal) {
        viewportGlobalListenable.value = _viewportGlobal;
      }
      if (viewportLocalListenable.value != _viewportLocal) {
        viewportLocalListenable.value = _viewportLocal;
      }
      notifyListeners();
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_notifyScheduled) return;
      _notifyScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _notifyScheduled = false;
        // The page (and this tracker) can be gone before the frame ends.
        if (!_isMounted()) return;
        publish();
      });
      return;
    }
    publish();
  }

  @override
  void dispose() {
    _position?.removeListener(_onScrollTick);
    onPlanVerticalDragCancel();
    contentHeightListenable.dispose();
    viewportGlobalListenable.dispose();
    viewportLocalListenable.dispose();
    super.dispose();
  }
}

class _FoundScrollable {
  const _FoundScrollable(this.state);

  final ScrollableState state;
}
