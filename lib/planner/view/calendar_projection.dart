import 'package:flutter/material.dart';

import '../../nodes/model/node.dart';
import '../../nodes/service/node_calendar.dart';
import '../../reporting/model/reported_entry.dart';
import '../bloc/calendar_visibility_cubit.dart';
import '../model/calendar_source.dart';
import '../model/color_prefs.dart';
import '../model/feed.dart';
import '../model/planner_event.dart';
import '../service/calendar_report.dart';
import 'event_colors.dart';

/// Page-owned derived state. Draft keystrokes, selection and resize frames
/// reuse unchanged store projections instead of rebuilding the entire store.
/// Nothing here is persisted; cubit state remains the source of truth.
class CalendarProjection {
  List<PlannerEvent>? _eventSource;
  List<Feed>? _feedSource;
  CalendarVisibilityState? _visibilitySource;
  List<Node>? _nodeSource;
  List<PlannerEvent> _visible = const [];
  List<PlannerEvent> _nodeBlocks = const [];
  List<PlannerEvent>? _reportVisible;
  List<Node>? _reportNodes;
  Map<String, List<ReportedEntry>>? _reportSource;
  DateTime? _reportTime;
  List<PlannerEvent> _reportEvents = const [];
  Map<String, ReportBlock> reportById = const {};
  Map<String, Color> reportColorById = const {};

  /// Event ids with at least one report block (live, timer, or accepted).
  /// Plan tiles read this to decide whether the one-tap copy-to-report
  /// badge applies — O(1) per tile instead of scanning blocks per frame.
  Set<String> reportedEventIds = const {};

  /// Report blocks per visible day (keyed by midnight), for the Plan +
  /// Report overlay: each day's lane paints its own list beside the plans.
  Map<DateTime, List<ReportBlock>> reportBlocksByDay = const {};
  bool _laneMode = false;
  bool _reportModeOn = false;
  bool _reportLiveOnly = false;
  List<DateTime>? _laneDays;
  double _laneStartHour = 0;
  double _laneEndHour = 24;
  bool _hasTracking = false;
  List<PlannerEvent>? _shownVisible;
  List<PlannerEvent>? _shownNodes;
  List<PlannerEvent>? _shownReports;
  PlannerEvent? _shownDraft;
  PlannerEvent? _shownEdit;
  PlannerEvent? _shownResize;
  List<PlannerEvent> shown = const [];
  Map<String, Color> feedColors = const {};
  Map<String, Color> colorById = const {};
  Set<String> remoteEditableFeedIds = const {};
  Map<String, Node> nodeById = const {};
  Map<String, Node> nodeByEventId = const {};
  Set<String> trackingNodeIds = const {};
  Set<String> trackingEventIds = const {};
  Map<String, String> assigneeLabelById = const {};
  Map<PlannerEvent, Color> _eventColors = Map.identity();
  ColorPrefs _colorPrefs = const ColorPrefs();

  void update({
    required List<PlannerEvent> events,
    required List<Feed> feeds,
    required CalendarVisibilityState visibility,
    required List<Node> nodes,
    required Map<String, List<ReportedEntry>> reports,
    required bool showReports,
    required DateTime now,
    bool showReportLanes = false,
    List<DateTime> visibleDays = const <DateTime>[],
    double visibleStartHour = 0,
    double visibleEndHour = 24,
    ColorPrefs colorPrefs = const ColorPrefs(),
    PlannerEvent? draft,
    PlannerEvent? edit,
    PlannerEvent? resize,
  }) {
    final feedsChanged = !identical(feeds, _feedSource);
    final eventsChanged = !identical(events, _eventSource);
    final nodesChanged = !identical(nodes, _nodeSource);
    final colorPrefsChanged = colorPrefs != _colorPrefs;
    _colorPrefs = colorPrefs;
    // Lane mode needs the visible day(s) to place one report lane per day.
    // Without them (and in the month view) report blocks stay appointments.
    final laneMode = showReportLanes && visibleDays.isNotEmpty;
    if (feedsChanged) {
      feedColors = {for (final feed in feeds) feed.id: feed.color};
      remoteEditableFeedIds = {
        for (final feed in feeds)
          if (feed.kind == FeedKind.google &&
              feed.calendarId != null &&
              feed.calendarId!.isNotEmpty)
            feed.id,
      };
    }
    // Homework detection reads the linked node, and color choices can
    // change on any settings edit, so both invalidate cached tile colors.
    if (feedsChanged || nodesChanged || colorPrefsChanged) {
      _eventColors = Map.identity();
    }
    if (eventsChanged ||
        feedsChanged ||
        !identical(visibility, _visibilitySource)) {
      final byId = {for (final feed in feeds) feed.id: feed};
      _visible = [
        for (final event in events)
          if (_isVisible(event, byId, visibility)) event,
      ];
    }
    if (nodesChanged) {
      _nodeBlocks = nodeCalendarBlocks(nodes);
      nodeById = {for (final node in nodes) node.id: node};
      final linked = <String, Node>{};
      final tracking = <String>{};
      for (final node in nodes) {
        final calendarId = node.calendarEventId;
        if (calendarId != null) linked.putIfAbsent(calendarId, () => node);
        final sourceId = node.sourceEventId;
        if (sourceId != null) linked.putIfAbsent(sourceId, () => node);
        linked.putIfAbsent('task:${node.id}', () => node);
        if (node.isTracking) tracking.add(node.id);
      }
      nodeByEventId = linked;
      trackingNodeIds = tracking;
    }
    if (eventsChanged ||
        nodesChanged ||
        feedsChanged ||
        !identical(visibility, _visibilitySource)) {
      _hasTracking =
          trackingNodeIds.isNotEmpty ||
          _visible.any((event) => event.isTracking);
    }
    _eventSource = events;
    _feedSource = feeds;
    _visibilitySource = visibility;
    _nodeSource = nodes;

    // Plans mode normally hides reports, but a recording started on a goal
    // (or any node without a calendar block) has no appointment of its own.
    // Keep just that live block in the grid so the Calendar reflects the
    // same running timer the Goals page shows.
    final liveOnly = !showReports && _hasTracking;
    final showAnyReports = showReports || liveOnly;
    if (!showAnyReports) {
      if (_reportEvents.isNotEmpty ||
          reportById.isNotEmpty ||
          reportedEventIds.isNotEmpty ||
          _reportModeOn ||
          _reportLiveOnly) {
        _reportEvents = const [];
        reportById = const {};
        reportedEventIds = const {};
        reportColorById = const {};
        reportBlocksByDay = const {};
        _reportModeOn = false;
        _reportLiveOnly = false;
        _laneMode = false;
        _reportVisible = _visible;
        _reportNodes = nodes;
        _reportSource = reports;
        _reportTime = now;
      }
    } else if (showReports != _reportModeOn ||
        liveOnly != _reportLiveOnly ||
        !identical(_visible, _reportVisible) ||
        !identical(nodes, _reportNodes) ||
        !identical(reports, _reportSource) ||
        colorPrefsChanged ||
        laneMode != _laneMode ||
        (laneMode &&
            (!_sameDays(visibleDays, _laneDays) ||
                visibleStartHour != _laneStartHour ||
                visibleEndHour != _laneEndHour)) ||
        (_hasTracking &&
            (_reportTime == null ||
                now.difference(_reportTime!) >=
                    const Duration(seconds: 15)))) {
      var blocks = buildReportBlocks(
        visibleEvents: _visible,
        nodes: nodes,
        reportsByDay: reports,
        now: now,
      );
      if (liveOnly) {
        blocks = [
          for (final block in blocks)
            if (block.kind == ReportBlockKind.live &&
                block.eventId == null &&
                !(nodeById[reportOwnerIdForDisplayId(block.displayId)]
                        ?.hasCalendarBlock ??
                    false))
              block,
        ];
      }
      final byId = {for (final event in _visible) event.id: event};
      _reportEvents = [
        for (final block in blocks)
          reportBlockToDisplayEvent(block, template: byId[block.eventId]),
      ];
      reportById = {for (final block in blocks) block.displayId: block};
      reportedEventIds = reportedEventIdsFor(blocks, _visible, nodes);
      // Chips live in the lane tile now, so their colors come straight from
      // the block's template (course/label/feed) instead of the calendar's
      // colorById, which only covers appointments in `shown`.
      reportColorById = {
        for (final event in _reportEvents)
          event.id: calendarEventColor(
            event,
            feedColors,
            prefs: _colorPrefs,
            node: _nodeFor(event),
          ),
      };
      _rebuildReportDays(
        blocks: blocks,
        days: visibleDays,
        startHour: visibleStartHour,
        endHour: visibleEndHour,
      );
      _laneMode = showReports && laneMode;
      _reportModeOn = showReports;
      _reportLiveOnly = liveOnly;
      _laneDays = List<DateTime>.of(visibleDays);
      _laneStartHour = visibleStartHour;
      _laneEndHour = visibleEndHour;
      _reportVisible = _visible;
      _reportNodes = nodes;
      _reportSource = reports;
      _reportTime = now;
    }
    // In lane mode the overlay owns report blocks, so they stay out of
    // `shown`; plans mode keeps live recordings and the month view keeps
    // every report as an ordinary agenda chip.
    final reportEvents = _laneMode && showReports
        ? const <PlannerEvent>[]
        : _reportEvents;
    if (identical(_shownVisible, _visible) &&
        identical(_shownNodes, _nodeBlocks) &&
        identical(_shownReports, reportEvents) &&
        identical(_shownDraft, draft) &&
        identical(_shownEdit, edit) &&
        identical(_shownResize, resize) &&
        !colorPrefsChanged) {
      return;
    }
    _shownVisible = _visible;
    _shownNodes = _nodeBlocks;
    _shownReports = reportEvents;
    _shownDraft = draft;
    _shownEdit = edit;
    _shownResize = resize;
    // Resize wins over the editor preview for both stored events and
    // synthesized node blocks. Node resize handles need the same live
    // feedback as ordinary event handles.
    shown = [
      for (final event in [
        ..._visible,
        if (draft != null) draft,
        ...reportEvents,
        ..._nodeBlocks,
      ])
        if (resize != null && event.id == resize.id)
          resize
        else if (edit != null && event.id == edit.id)
          edit
        else
          event,
    ];
    final colors = <String, Color>{};
    final retainedColors = Map<PlannerEvent, Color>.identity();
    final tracking = <String>{};
    final assignees = <String, String>{};
    for (final event in shown) {
      final color =
          _eventColors[event] ??
          calendarEventColor(
            event,
            feedColors,
            prefs: _colorPrefs,
            node: _nodeFor(event),
          );
      colors[event.id] = color;
      retainedColors[event] = color;
      if (event.isTracking) tracking.add(event.id);
      if (event.assignees.isNotEmpty) {
        assignees[event.id] = event.assignees
            .map((a) => a.displayName)
            .join(', ');
      }
    }
    colorById = colors;
    _eventColors = retainedColors;
    trackingEventIds = tracking;
    assigneeLabelById = assignees;
  }

  /// The node backing [event], when one is loaded: personal links and
  /// homework shadows map through their back-links, schedule blocks
  /// through the `node:` id prefix.
  Node? _nodeFor(PlannerEvent event) {
    final linked = nodeByEventId[event.id];
    if (linked != null) return linked;
    if (isNodeBlockId(event.id)) {
      return nodeById[nodeIdFromBlockId(event.id)];
    }
    return null;
  }

  bool _isVisible(
    PlannerEvent event,
    Map<String, Feed> feeds,
    CalendarVisibilityState visibility,
  ) {
    final feed = feeds[event.feedId];
    if (feed != null && !feed.enabled) return false;
    final leaf = calendarLeafIdForEvent(event, feed);
    return !visibility.isHidden(leaf) &&
        !visibility.isHidden(groupIdForLeaf(leaf, feed));
  }

  /// Groups report blocks by the visible days the overlay paints, dropping
  /// blocks that fall entirely outside the grid's hour range (they would
  /// paint nothing). Every visible day gets an entry — empty when it has no
  /// reports — so the overlay always covers each day cell.
  void _rebuildReportDays({
    required List<ReportBlock> blocks,
    required List<DateTime> days,
    required double startHour,
    required double endHour,
  }) {
    if (days.isEmpty) {
      reportBlocksByDay = const {};
      return;
    }
    final grouped = groupReportBlocksByDay(blocks);
    final byDay = <DateTime, List<ReportBlock>>{};
    for (final visible in days) {
      final day = DateTime(visible.year, visible.month, visible.day);
      final gridStart = day.add(Duration(minutes: (startHour * 60).round()));
      final gridEnd = day.add(Duration(minutes: (endHour * 60).round()));
      byDay[day] = [
        for (final block in grouped[day] ?? const <ReportBlock>[])
          if (block.end.isAfter(gridStart) && block.start.isBefore(gridEnd))
            block,
      ];
    }
    reportBlocksByDay = byDay;
  }

  bool _sameDays(List<DateTime> days, List<DateTime>? previous) {
    if (previous == null || days.length != previous.length) return false;
    for (var i = 0; i < days.length; i++) {
      if (days[i] != previous[i]) return false;
    }
    return true;
  }
}

Color calendarEventColor(
  PlannerEvent event,
  Map<String, Color> feedColors, {
  ColorPrefs prefs = const ColorPrefs(),
  Node? node,
}) => resolveEventColor(event, feedColors, prefs, node: node);
