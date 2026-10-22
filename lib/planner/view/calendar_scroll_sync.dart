import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Keeps the plan and report calendars on one vertical time-grid offset.
///
/// Syncfusion keeps each calendar's scroll controller private, so this
/// coordinator captures the [ScrollPosition] from appointment builders and
/// synchronizes the two positions through their notifications.
class CalendarScrollSync {
  CalendarScrollSync({
    required bool Function() isMounted,
    required double timeGridViewportThreshold,
  }) : _isMounted = isMounted,
       _timeGridViewportThreshold = timeGridViewportThreshold;

  final bool Function() _isMounted;
  final double _timeGridViewportThreshold;
  ScrollPosition? _planScroll;
  ScrollPosition? _railScroll;
  Rect? _planTimeViewportGlobal;
  bool _syncingScroll = false;
  int _scrollSyncGeneration = 0;
  bool _initialScrollSynced = false;
  bool _scrollSyncScheduled = false;

  Rect? get planTimeViewportGlobal => _planTimeViewportGlobal;

  bool onPlanScroll(ScrollNotification notification) {
    final position = _captureVerticalScroll(notification);
    if (!_isTimeGridPosition(position, _planScroll)) return false;
    if (position != null) _planScroll = position;
    _mirrorScroll(from: position, to: _railScroll);
    return false;
  }

  bool onRailScroll(ScrollNotification notification) {
    final position = _captureVerticalScroll(notification);
    if (!_isTimeGridPosition(position, _railScroll)) return false;
    if (position != null) _railScroll = position;
    _mirrorScroll(from: position, to: _planScroll);
    return false;
  }

  bool _isTimeGridPosition(ScrollPosition? position, ScrollPosition? known) {
    if (position == null || !position.hasPixels) return false;
    if (identical(position, known)) return true;
    // Before a timed appointment gives us its ScrollPosition, ignore the
    // smaller all-day-panel Scrollable's notifications.
    return known == null &&
        position.axis == Axis.vertical &&
        position.viewportDimension > _timeGridViewportThreshold;
  }

  void onPlanPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final plan = _planScroll;
    if (plan == null || !plan.hasPixels) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (signal) {
      if (!_isMounted() || !plan.hasPixels) return;
      plan.pointerScroll((signal as PointerScrollEvent).scrollDelta.dy);
    });
  }

  void onPlanVerticalDrag(DragUpdateDetails details) {
    final plan = _planScroll;
    if (plan == null || !plan.hasPixels) return;
    final target = (plan.pixels - details.delta.dy).clamp(
      plan.minScrollExtent,
      plan.maxScrollExtent,
    );
    if ((plan.pixels - target).abs() < 0.5) return;
    plan.jumpTo(target);
  }

  /// Captures the scroll position and the time-grid viewport from an
  /// appointment builder. This also supplies the first plan → report
  /// alignment when the calendars are initially laid out.
  void rememberPosition(
    BuildContext context, {
    required bool rail,
    bool timeGrid = false,
  }) {
    if (!timeGrid) return;
    final scrollable = Scrollable.maybeOf(context);
    final position = scrollable?.position;
    final render = scrollable?.context.findRenderObject();
    if (!rail && render is RenderBox && render.hasSize) {
      _planTimeViewportGlobal = render.localToGlobal(Offset.zero) & render.size;
    }
    if (position == null ||
        !position.hasPixels ||
        position.axis != Axis.vertical) {
      return;
    }
    if (rail) {
      if (identical(_railScroll, position)) return;
      _railScroll = position;
    } else {
      if (identical(_planScroll, position)) return;
      _planScroll = position;
    }
    _scheduleInitialScrollSync();
  }

  void _scheduleInitialScrollSync() {
    if (_initialScrollSynced || _scrollSyncScheduled) return;
    _scrollSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollSyncScheduled = false;
      if (!_isMounted() || _initialScrollSynced) return;
      final plan = _planScroll;
      final rail = _railScroll;
      if (plan == null || rail == null) return;
      _initialScrollSynced = true;
      _mirrorScroll(from: plan, to: rail);
    });
  }

  ScrollPosition? _captureVerticalScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return null;
    final context = notification.context;
    if (context == null) return null;
    // The documented way to reach the ScrollableState that sent the
    // notification (see Flutter's Scrollable.build comment).
    return Scrollable.maybeOf(context)?.position;
  }

  void _mirrorScroll({ScrollPosition? from, ScrollPosition? to}) {
    if (_syncingScroll || from == null || to == null || !to.hasPixels) return;
    final target = from.pixels.clamp(to.minScrollExtent, to.maxScrollExtent);
    if ((to.pixels - target).abs() < 0.5) return;
    _syncingScroll = true;
    final generation = ++_scrollSyncGeneration;
    try {
      to.jumpTo(target);
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (generation == _scrollSyncGeneration) _syncingScroll = false;
      });
    }
  }
}
