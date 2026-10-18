import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

import '../../common/undo/undo_bar.dart';
import '../../common/undo/undo_cubit.dart';
import '../../navigation/view/app_drawer.dart';
import '../../navigation/bloc/navigation_cubit.dart';
import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/model/node.dart';
import '../../nodes/service/node_calendar.dart';
import '../../nodes/service/node_event_link.dart';
import '../../nodes/service/node_event_sync.dart';
import '../../nodes/view/node_checkbox.dart';
import '../../nodes/view/node_editor.dart';
import '../../nodes/view/node_finish_sheet.dart';
import '../../nodes/view/schedule_sheet.dart';
import '../../reporting/bloc/reporting_cubit.dart';
import '../../reporting/model/reported_entry.dart';
import '../../reporting/view/day_review_screen.dart';
import '../bloc/calendar_cubit.dart';
import '../bloc/calendar_draft_cubit.dart';
import '../bloc/calendar_visibility_cubit.dart';
import '../bloc/feed_cubit.dart';
import '../model/event_reschedule.dart';
import '../model/planner_event.dart';
import '../bloc/settings_cubit.dart';
import '../service/calendar_report.dart';
import '../service/event_reminders.dart';
import 'calendar_data_source.dart';
import 'calendar_projection.dart';
import 'calendar_filter_sheet.dart';
import 'calendar_report_lane.dart';
import 'calendar_side_panel.dart';
import 'event_editor.dart';
import 'feed_manager.dart';
import 'tasks_panel.dart';

const double _wideBreakpoint = 720;

/// Wide desktops land on the calendar with the task panel open; smaller
/// (but still wide) windows stay calendar-first until the panel is opened.
const double _panelDefaultBreakpoint = 1080;

// Hoisted: DateFormat construction parses ICU skeletons — doing it per tile
// per frame (30+ tiles) showed up in profiles.
final _calendarTimeFormat = DateFormat('h:mm a');
final _calendarMoveFormat = DateFormat('EEE, MMM d · h:mm a');
final _calendarDayFormat = DateFormat('EEE, MMM d');

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  final CalendarController _controller = CalendarController();
  CalendarView _view = platformDefaultCalendarView;
  String? _selectedEventId;

  /// What the side panel shows while open. [CalendarPanelMode.tasks] with
  /// nothing selected is the panel's resting state.
  CalendarPanelMode _panelMode = CalendarPanelMode.tasks;

  /// Whether the side panel (wide screens only) is shown.
  bool _panelOpen = false;
  bool _appliedPanelDefault = false;

  /// True when a pending draft was claimed as the page mounted (the user
  /// navigated here from Tasks → Pick time on calendar): saving it returns
  /// to Tasks. Seeds arriving while the page is already open (the side
  /// panel's own schedule flow) keep the user on the calendar.
  bool _seedFromPageMount = false;
  PlannerEvent? _draftEvent;
  String? _draftSeedSubject;
  String? _draftSeedNotes;
  String? _draftSeedLocation;
  String? _draftSeedClassLabel;
  String? _draftSeedTaskId;
  bool _suppressTap = false;
  bool _sideBySide = false;
  Timer? _liveTicker;
  Timer? _suppressTimer;
  PlannerCalendarDataSource? _dataSource;
  final _projection = CalendarProjection();
  TimeSlotViewSettings? _slotSettingsCache;
  double? _slotStartHour;
  double? _slotEndHour;

  TimeSlotViewSettings _slotSettings(double startHour, double endHour) {
    if (_slotSettingsCache == null ||
        _slotStartHour != startHour ||
        _slotEndHour != endHour) {
      _slotSettingsCache = TimeSlotViewSettings(
        timeInterval: const Duration(minutes: 30),
        startHour: startHour,
        endHour: endHour,
        // Default is 'h a' (e.g. "9 AM"), which renders 9:00 and 9:30
        // identically. Include minutes so each 30-min line is distinct.
        timeFormat: 'h:mm a',
        // Wide enough for "12:30 PM" on one line (auto size wraps it).
        timeRulerSize: 70,
      );
      _slotStartHour = startHour;
      _slotEndHour = endHour;
    }
    return _slotSettingsCache!;
  }

  /// Schedules the tap-suppression reset. Cancelable so a pending reset
  /// never outlives the widget (widget tests fail on leaked timers).
  void _resetSuppressSoon() {
    _suppressTimer?.cancel();
    _suppressTimer = Timer(const Duration(milliseconds: 300), () {
      _suppressTap = false;
    });
  }

  PlannerEvent? _resizePreview;
  // Live preview of the event being edited in the side drawer: the edit
  // form owns its time/label state until Save, so without this the tile
  // stays at the old time while the sidebar shows the new one.
  PlannerEvent? _editPreview;
  PlannerEvent? _handleOriginal;
  bool _handleTop = true;
  double _handleDy = 0;
  double _handlePxPerMinute = 1;
  bool _ignoreNativeDragEnd = false;
  bool _isDragging = false;

  bool get _isWide => MediaQuery.of(context).size.width >= _wideBreakpoint;
  bool _appliedNarrowDefault = false;

  @override
  void initState() {
    super.initState();
    _view = context.read<SettingsCubit>().state.defaultCalendarView;
    _controller.view = _view;
    _controller.addPropertyChangedListener(_onCalendarControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final pending = context.read<CalendarDraftCubit>().takePending();
      if (pending != null) {
        _seedFromPageMount = true;
        _openCreator(seed: pending);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_appliedNarrowDefault) {
      _appliedNarrowDefault = true;
      if (MediaQuery.of(context).size.width < _wideBreakpoint &&
          _view != CalendarView.day) {
        _view = CalendarView.day;
        _controller.view = _view;
      }
    }
    if (!_appliedPanelDefault) {
      _appliedPanelDefault = true;
      _panelOpen = MediaQuery.of(context).size.width >= _panelDefaultBreakpoint;
    }
  }

  @override
  void dispose() {
    _liveTicker?.cancel();
    _suppressTimer?.cancel();
    _controller.removePropertyChangedListener(_onCalendarControllerChanged);
    _dataSource?.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Navigation happens inside SfCalendar (header arrows, swipes): the
  /// controller tells us the display date moved, and the report lanes must
  /// follow it. Deferred to the frame's end — the controller can also be
  /// updated from inside the calendar's own build.
  void _onCalendarControllerChanged(String property) {
    if (!_sideBySide || _view == CalendarView.month) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  /// The days the report lanes must cover: what the calendar shows right
  /// now — the display date in the day view, its Sunday-start week in the
  /// week view. Lanes only exist while the Plan + Report view is on and a
  /// time-slot grid is visible (the month view keeps its agenda chips).
  List<DateTime> _visibleDaysForLane() {
    final display = _controller.displayDate ?? DateTime.now();
    final day = DateTime(display.year, display.month, display.day);
    if (_view == CalendarView.day) return [day];
    // firstDayOfWeek is 7 (Sunday): back up to the week's first day.
    final start = day.subtract(Duration(days: day.weekday % 7));
    return [for (var i = 0; i < 7; i++) start.add(Duration(days: i))];
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsCubit>().state;
    final snap = settings.snapMinutes;
    final panelVisible = _isWide && _panelOpen;
    // Narrow screens get a condensed single-row toolbar (icon-only
    // switches) and an abbreviated calendar header so the chrome above
    // the events stays one slim row tall.
    final compactHeader = !_isWide;
    final addEventFab = FloatingActionButton.extended(
      onPressed: _onAddPressed,
      icon: const Icon(Icons.add),
      label: const Text('Event'),
    );
    return BlocListener<CalendarDraftCubit, PlannerEvent?>(
      listener: (context, pending) {
        if (pending != null) {
          context.read<CalendarDraftCubit>().clear();
          // Live seed: the user is already here (side panel schedule flow).
          _seedFromPageMount = false;
          _openCreator(seed: pending);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Calendar'),
          actions: [
            if (_isWide)
              IconButton(
                tooltip: panelVisible ? 'Hide side panel' : 'Show tasks panel',
                isSelected: panelVisible,
                icon: const Icon(Icons.view_sidebar_outlined),
                selectedIcon: const Icon(Icons.view_sidebar),
                onPressed: _togglePanel,
              ),
            Builder(
              builder: (buttonContext) {
                final hasHidden = buttonContext
                    .watch<CalendarVisibilityCubit>()
                    .state
                    .hasHidden;
                return Badge(
                  isLabelVisible: hasHidden,
                  child: IconButton(
                    tooltip: 'Calendars',
                    icon: const Icon(Icons.layers_outlined),
                    onPressed: () => showCalendarFilterSheet(buttonContext),
                  ),
                );
              },
            ),
            IconButton(
              tooltip: 'Manage classes',
              icon: const Icon(Icons.sync),
              onPressed: () => showFeedManager(context),
            ),
            const UndoRedoActions(),
          ],
        ),
        drawer: const AppDrawer(),
        // The panel owns the right edge: with a task list up, the Event button
        // floats over the calendar pane instead (Stack below); while a form is
        // open it steps aside so it can't swallow Add/Save taps.
        floatingActionButton: panelVisible ? null : addEventFab,
        body: Column(
          children: [
            if (compactHeader)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: SegmentedButton<CalendarView>(
                        segments: const [
                          ButtonSegment(
                            value: CalendarView.day,
                            icon: Icon(Icons.view_day),
                            tooltip: 'Day (tap again for today)',
                          ),
                          ButtonSegment(
                            value: CalendarView.week,
                            icon: Icon(Icons.view_column),
                            tooltip: 'Week (tap again for today)',
                          ),
                          ButtonSegment(
                            value: CalendarView.month,
                            icon: Icon(Icons.calendar_view_month),
                            tooltip: 'Month (tap again for today)',
                          ),
                        ],
                        selected: {_view},
                        emptySelectionAllowed: true,
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onSelectionChanged: (selection) {
                          if (selection.isEmpty || selection.first == _view) {
                            _goToToday();
                          } else {
                            setState(() => _view = selection.first);
                            _controller.view = _view;
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                            value: false,
                            icon: Icon(Icons.calendar_month),
                            tooltip: 'Plans',
                          ),
                          ButtonSegment(
                            value: true,
                            icon: Icon(Icons.fact_check),
                            tooltip: 'Plan + Report',
                          ),
                        ],
                        selected: {_sideBySide},
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onSelectionChanged: (selection) {
                          _setSideBySide(selection.first);
                        },
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: SegmentedButton<CalendarView>(
                            segments: const [
                              ButtonSegment(
                                value: CalendarView.day,
                                icon: Icon(Icons.view_day),
                                label: Text('Day'),
                                tooltip: 'Day (tap again for today)',
                              ),
                              ButtonSegment(
                                value: CalendarView.week,
                                icon: Icon(Icons.view_column),
                                label: Text('Week'),
                                tooltip: 'Week (tap again for today)',
                              ),
                              ButtonSegment(
                                value: CalendarView.month,
                                icon: Icon(Icons.calendar_view_month),
                                label: Text('Month'),
                                tooltip: 'Month (tap again for today)',
                              ),
                            ],
                            selected: {_view},
                            emptySelectionAllowed: true,
                            showSelectedIcon: false,
                            style: const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              textStyle: WidgetStatePropertyAll(
                                TextStyle(fontSize: 13),
                              ),
                            ),
                            onSelectionChanged: (selection) {
                              if (selection.isEmpty ||
                                  selection.first == _view) {
                                _goToToday();
                              } else {
                                setState(() => _view = selection.first);
                                _controller.view = _view;
                              }
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: false,
                          icon: Icon(Icons.calendar_month),
                          label: Text('Plans'),
                        ),
                        ButtonSegment(
                          value: true,
                          icon: Icon(Icons.fact_check),
                          label: Text('Plan + Report'),
                        ),
                      ],
                      selected: {_sideBySide},
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: WidgetStatePropertyAll(
                          TextStyle(fontSize: 13),
                        ),
                      ),
                      onSelectionChanged: (selection) {
                        _setSideBySide(selection.first);
                      },
                    ),
                  ),
                ),
              ),
            ],
            if (_sideBySide)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Text(
                  'Each day: reports in their own column on the left, plans '
                  'beside them · red = recording now · ▶ on a tile starts '
                  'recording',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            // Toggl-style running-entry bar: always visible while an event
            // timer is recording, with elapsed time and Stop.
            _RecordingBannerSlot(
              onOpen: (event) {
                PlannerEvent? live;
                try {
                  live = context.read<CalendarCubit>().byId(event.id) ?? event;
                } catch (_) {
                  live = event;
                }
                _openDetail(live);
              },
            ),
            Expanded(
              child: BlocBuilder<CalendarCubit, List<PlannerEvent>>(
                builder: (context, events) {
                  final sideBySide = _sideBySide;
                  final wide = _isWide;
                  final reportLanes = sideBySide && _view != CalendarView.month;
                  _projection.update(
                    events: events,
                    feeds: context.watch<FeedCubit>().state,
                    visibility: context.watch<CalendarVisibilityCubit>().state,
                    nodes: context.watch<NodeCubit>().state,
                    reports: sideBySide
                        ? context.watch<ReportingCubit>().state
                        : const <String, List<ReportedEntry>>{},
                    showReports: sideBySide,
                    showReportLanes: reportLanes,
                    visibleDays: reportLanes ? _visibleDaysForLane() : const [],
                    visibleStartHour: settings.dayStartHour,
                    visibleEndHour: settings.dayEndHour,
                    now: DateTime.now(),
                    draft: wide && _panelMode == CalendarPanelMode.creating
                        ? _draftEvent
                        : null,
                    edit: wide && _panelMode == CalendarPanelMode.editing
                        ? _editPreview
                        : null,
                    resize: _resizePreview,
                  );
                  final shown = _projection.shown;
                  final feedColors = _projection.feedColors;
                  final colorById = _projection.colorById;
                  final reportById = sideBySide
                      ? _projection.reportById
                      : const <String, ReportBlock>{};
                  final reportBlocksByLaneId = reportLanes
                      ? _projection.reportBlocksByLaneId
                      : const <String, List<ReportBlock>>{};
                  final reportColorById = reportLanes
                      ? _projection.reportColorById
                      : const <String, Color>{};
                  if (_dataSource == null) {
                    _dataSource = PlannerCalendarDataSource(
                      shown,
                      feedColors,
                      colorById,
                    );
                  } else if (!_dataSource!.matches(
                    shown,
                    feedColors,
                    colorById,
                  )) {
                    _dataSource!.update(shown, feedColors, colorById);
                  }
                  final calendar = SfCalendar(
                    controller: _controller,
                    view: _view,
                    dataSource: _dataSource!,
                    firstDayOfWeek: 7,
                    allowDragAndDrop: true,
                    allowAppointmentResize: false,
                    dragAndDropSettings: const DragAndDropSettings(
                      allowNavigation: true,
                      allowScroll: true,
                      autoNavigateDelay: Duration(milliseconds: 500),
                      showTimeIndicator: true,
                    ),
                    appointmentBuilder: (context, details) =>
                        _appointmentBuilder(
                          feedColors,
                          context,
                          details,
                          reportById: reportById,
                          reportBlocksByLaneId: reportBlocksByLaneId,
                          reportColorById: reportColorById,
                          laneStartHour: settings.dayStartHour,
                          laneEndHour: settings.dayEndHour,
                          colorById: colorById,
                          remoteEditableFeedIds:
                              _projection.remoteEditableFeedIds,
                          nodeById: _projection.nodeById,
                          nodeByEventId: _projection.nodeByEventId,
                          trackingNodeIds: _projection.trackingNodeIds,
                          trackingEventIds: _projection.trackingEventIds,
                          assigneeLabelById: _projection.assigneeLabelById,
                        ),
                    onDragStart: _onDragStart,
                    onDragEnd: _onDragEnd,
                    onTap: _onTap,
                    onViewChanged: _onViewChanged,
                    monthViewSettings: const MonthViewSettings(
                      showAgenda: true,
                      appointmentDisplayMode:
                          MonthAppointmentDisplayMode.appointment,
                      agendaItemHeight: 44,
                    ),
                    timeSlotViewSettings: _slotSettings(
                      settings.dayStartHour,
                      settings.dayEndHour,
                    ),
                    todayHighlightColor: Theme.of(context).colorScheme.primary,
                    headerDateFormat: compactHeader ? 'MMM y' : null,
                    headerHeight: compactHeader ? 32 : 40,
                    headerStyle: compactHeader
                        ? const CalendarHeaderStyle(
                            textStyle: TextStyle(fontSize: 14),
                          )
                        : const CalendarHeaderStyle(),
                    showNavigationArrow: true,
                  );
                  // Keep the calendar at a stable tree position. Opening a
                  // drawer or report hint must not dispose/recreate SfCalendar
                  // and regenerate every appointment (or leave its scheduled
                  // data-source callbacks pointing at a disposed state).
                  final calendarView = Stack(
                    children: [
                      calendar,
                      if (sideBySide && reportById.isEmpty)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 12,
                          child: _noReportHint(),
                        ),
                      // With the panel open the Event button anchors to the
                      // calendar pane instead of hovering over the panel.
                      if (panelVisible && _panelMode == CalendarPanelMode.tasks)
                        Positioned(right: 16, bottom: 16, child: addEventFab),
                    ],
                  );
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: calendarView),
                      if (panelVisible) _buildSidePanel(snap),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _appointmentBuilder(
    Map<String, Color> feedColors,
    BuildContext context,
    CalendarAppointmentDetails details, {
    required Map<String, ReportBlock> reportById,
    Map<String, List<ReportBlock>>? reportBlocksByLaneId,
    Map<String, Color>? reportColorById,
    double laneStartHour = 0,
    double laneEndHour = 24,
    Map<String, Color>? colorById,
    Set<String>? remoteEditableFeedIds,
    Map<String, Node>? nodeById,
    Map<String, Node>? nodeByEventId,
    Set<String>? trackingNodeIds,
    Set<String>? trackingEventIds,
    Map<String, String>? assigneeLabelById,
  }) {
    if (details.isMoreAppointmentRegion) {
      return Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          '+${details.appointments.length}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      );
    }
    final raw = details.appointments.isNotEmpty
        ? details.appointments.first
        : null;
    final event = raw is PlannerEvent ? raw : null;
    if (event == null) return const SizedBox.shrink();
    // Report lane: the day's left column. Its tile is the lane itself
    // (background + time-positioned report chips), not an event tile.
    final laneBlocks = reportBlocksByLaneId?[event.id];
    if (laneBlocks != null) {
      return ReportLaneView(
        blocks: laneBlocks,
        day: reportLaneDayOf(event.id) ?? event.start,
        startHour: laneStartHour,
        endHour: laneEndHour,
        colorFor: (block) =>
            reportColorById?[block.displayId] ??
            const Color(defaultPersonalEventColor),
        onTap: (block) {
          // The calendar's own tap handler would otherwise also fire and
          // treat the lane placeholder as a tapped event.
          _suppressNextTap();
          _openReport(block.displayId);
        },
      );
    }
    final report = reportById[event.id];
    final isDraft = event.id == calendarDraftEventId;
    final baseColor = colorById?[event.id] ?? _eventColor(event, feedColors);
    var color = isDraft ? baseColor.withValues(alpha: 0.55) : baseColor;
    if (event.isTask && event.done) {
      color = color.withValues(alpha: 0.55);
    }
    if (report != null && report.kind != ReportBlockKind.live) {
      color = color.withValues(alpha: 0.7);
    }
    final selected = event.id == _selectedEventId;
    // Resize circles show only on the selected event (tap opens the side
    // drawer and selects). Unselected events stay clean, especially on
    // wide/web where many events are visible at once.
    final bool movable;
    if (isDraft) {
      movable = report == null;
    } else if (!selected || report != null) {
      movable = false;
    } else if (remoteEditableFeedIds != null) {
      movable = _isMovableFast(event, remoteEditableFeedIds);
    } else {
      movable = _isMovable(event) && selected;
    }
    final displaySubject = isDraft && event.subject.trim().isEmpty
        ? 'New event'
        : event.subject;
    final String timeLabel;
    if (report == null) {
      timeLabel = event.allDay
          ? 'All day'
          : '${_calendarTimeFormat.format(event.start)} – ${_calendarTimeFormat.format(event.end)}';
    } else {
      final range =
          '${_calendarTimeFormat.format(event.start)} – ${_calendarTimeFormat.format(event.end)}';
      timeLabel = switch (report.kind) {
        ReportBlockKind.live =>
          'Recording since ${_calendarTimeFormat.format(event.start)}',
        ReportBlockKind.timer => '$range · timer',
        ReportBlockKind.accepted => '$range · accepted',
      };
    }
    final durationMinutes = event.end.isAfter(event.start)
        ? event.end.difference(event.start).inSeconds / 60.0
        : 60.0;
    final Widget tile = Opacity(
      key: ValueKey('tile:${event.id}'),
      opacity: isDraft ? 0.85 : 1,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(6),
          border: (selected || isDraft)
              ? Border.all(color: Colors.white, width: 2)
              : report?.kind == ReportBlockKind.live
              ? Border.all(color: const Color(0xFFFF5252), width: 2)
              : null,
          boxShadow: selected
              ? const [
                  BoxShadow(
                    color: Colors.black38,
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // details.bounds doesn't always match the rendered box, so all
            // sizing decisions use the measured height (falling back to the
            // reported bounds when unbounded).
            final realHeight = constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : details.bounds.height;
            final showText = realHeight.isInfinite || realHeight >= 20;
            final showTime = realHeight.isInfinite || realHeight >= 34;
            final twoLines = realHeight.isInfinite || realHeight >= 58;
            final maxWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : null;
            // A 15-min event measures ~15px tall here (40px per 30-min
            // interval minus the calendar's appointment insets), so the
            // floor sits just under that: anything shorter can't show two
            // tappable circles and falls back to the edit form.
            final showHandles =
                movable &&
                !event.allDay &&
                (realHeight.isInfinite || realHeight >= 12) &&
                (maxWidth == null || maxWidth >= 48);
            // Full-size circles need room (both 28px grabs stacked plus the
            // title row). Below that — e.g. a 15-min event is ~25px at the
            // 30-min/50px interval — fall back to compact circles so a
            // shortened event can still be dragged long again. Without this
            // the handles vanished the moment a drag made the tile short.
            final compactHandles =
                showHandles &&
                !((realHeight.isInfinite || realHeight >= 58) &&
                    (maxWidth == null || maxWidth >= 96));
            // Very short tiles can't stack two grabs vertically without the
            // circles landing on top of each other, so offset them to
            // opposite corners (start = top-left, end = bottom-right).
            final tightHandles =
                compactHandles && realHeight.isFinite && realHeight < 40;
            final pxPerMinute =
                (realHeight.isFinite ? realHeight : details.bounds.height) /
                durationMinutes.clamp(1.0, 1440.0);
            Widget body = Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (report?.kind == ReportBlockKind.live)
                      const Padding(
                        padding: EdgeInsets.only(right: 3),
                        child: Icon(
                          Icons.fiber_manual_record,
                          size: 12,
                          color: Color(0xFFFF5252),
                        ),
                      ),
                    if (report?.kind == ReportBlockKind.timer)
                      const Padding(
                        padding: EdgeInsets.only(right: 3),
                        child: Icon(
                          Icons.timer_outlined,
                          size: 12,
                          color: Colors.white,
                        ),
                      ),
                    if (report?.kind == ReportBlockKind.accepted)
                      const Padding(
                        padding: EdgeInsets.only(right: 3),
                        child: Icon(
                          Icons.fact_check,
                          size: 12,
                          color: Colors.white,
                        ),
                      ),
                    if (isDraft)
                      const Padding(
                        padding: EdgeInsets.only(right: 3),
                        child: Icon(
                          Icons.edit_calendar,
                          size: 12,
                          color: Colors.white,
                        ),
                      ),
                    if (event.isTask)
                      Padding(
                        padding: const EdgeInsets.only(right: 1),
                        child: GestureDetector(
                          onTapDown: (_) => _suppressNextTap(),
                          child: IconTheme(
                            data: const IconThemeData(color: Colors.white),
                            child: _blockCheckbox(
                              event: event,
                              size: 20,
                              doneColor: Colors.white,
                              nodeById: nodeById,
                              nodeByEventId: nodeByEventId,
                              liveEvent: event,
                            ),
                          ),
                        ),
                      ),
                    Flexible(
                      child: Text(
                        displaySubject,
                        maxLines: twoLines ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          fontStyle: isDraft
                              ? FontStyle.italic
                              : FontStyle.normal,
                          decoration: event.isTask && event.done
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                    ),
                    if (event.assignees.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 3),
                        child: Tooltip(
                          message:
                              assigneeLabelById?[event.id] ??
                              event.assignees
                                  .map((a) => a.displayName)
                                  .join(', '),
                          child: const Icon(
                            Icons.group,
                            size: 12,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
                if (showTime) ...[
                  const SizedBox(height: 2),
                  Text(
                    timeLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ],
              ],
            );
            // Belt and braces: never let text overflow a cramped box.
            if (maxWidth != null) {
              body = SizedBox(
                width: maxWidth,
                height: realHeight.isFinite ? realHeight : null,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: maxWidth, child: body),
                ),
              );
            }
            return Stack(
              // Hard edge: nothing (badge, handles) may paint outside the
              // tile. With Clip.none a 28px badge on a ~20px 15-min tile
              // overflowed onto the empty grid and read as a floating ▶
              // disconnected from any event.
              clipBehavior: Clip.hardEdge,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                  child: showText ? body : const SizedBox.shrink(),
                ),
                if (showHandles)
                  // Narrow grab area centered on the visible circle: a
                  // full-width strip would swallow taps on the header row
                  // (title, checkbox, play button) whenever handles show.
                  // Compact tiles use a slimmer strip so the smaller circle
                  // stays clear of the title on narrow week columns.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: SizedBox(
                        width: compactHandles ? 40 : 48,
                        child: _resizeHandle(
                          top: true,
                          event: event,
                          color: baseColor,
                          pxPerMinute: pxPerMinute,
                          compact: compactHandles,
                          tight: tightHandles,
                        ),
                      ),
                    ),
                  ),
                if (showHandles)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: SizedBox(
                        width: compactHandles ? 40 : 48,
                        child: _resizeHandle(
                          top: false,
                          event: event,
                          color: baseColor,
                          pxPerMinute: pxPerMinute,
                          compact: compactHandles,
                          tight: tightHandles,
                        ),
                      ),
                    ),
                  ),
                // Toggl-style one-tap recording badge, pinned top-right so it
                // never shrinks with the title text and always sits above the
                // full-size resize handles. Compact handles (short selected
                // tiles) take priority instead: the badge would bury the
                // smaller circle — start recording from the open detail view.
                // Covers timed tiles in day/week views that
                // are big enough to hold it (28px badge + offsets); smaller
                // tiles (15-min events, thin side-by-side halves, crowded
                // overlaps) skip it — an overflowing badge reads as a
                // floating ▶ disconnected from any tile. Month cells stay
                // clean (too many tiny tiles to tap reliably).
                if (report == null &&
                    !isDraft &&
                    !event.allDay &&
                    !isReportDisplayId(event.id) &&
                    !isNodeBlockId(event.id) &&
                    !compactHandles &&
                    _view != CalendarView.month &&
                    (realHeight.isInfinite || realHeight >= 30) &&
                    (maxWidth == null || maxWidth >= 36))
                  Positioned(
                    top: 2,
                    right: 2,
                    child: _tilePlayBadge(
                      event,
                      backing: _backingNodeFor(
                        context,
                        event,
                        nodeByEventId: nodeByEventId,
                        nodeById: nodeById,
                      ),
                      tracking: _tileTrackingFor(
                        event,
                        nodeByEventId: nodeByEventId,
                        nodeById: nodeById,
                        trackingNodeIds: trackingNodeIds,
                        trackingEventIds: trackingEventIds,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
    return tile;
  }

  Widget _resizeHandle({
    required bool top,
    required PlannerEvent event,
    required Color color,
    required double pxPerMinute,
    bool compact = false,
    bool tight = false,
  }) {
    // Compact circles (14px in a 20px grab) fit short tiles where two
    // full-size grabs would fully overlap. Only the painted circle takes
    // hits (deferToChild): near-misses fall through to the tile so taps
    // near a handle still select/open the event, and overlapping grabs
    // resolve to whichever circle is on top. On very short tiles the
    // circles also split to opposite corners so both stay tappable.
    final grabHeight = compact ? 20.0 : 28.0;
    final diameter = compact ? 14.0 : 18.0;
    final alignment = top
        ? (tight ? Alignment.topLeft : Alignment.topCenter)
        : (tight ? Alignment.bottomRight : Alignment.bottomCenter);
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onVerticalDragStart: (_) => _onHandleDragStart(event, top, pxPerMinute),
      onVerticalDragUpdate: _onHandleDragUpdate,
      onVerticalDragEnd: (_) => _onHandleDragEnd(),
      onVerticalDragCancel: _onHandleDragCancel,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpDown,
        child: Container(
          height: grabHeight,
          alignment: alignment,
          padding: EdgeInsets.only(
            top: 2,
            bottom: 2,
            left: tight ? 6 : 0,
            right: tight ? 6 : 0,
          ),
          child: Semantics(
            label: top
                ? 'Drag to change start time'
                : 'Drag to change end time',
            child: Container(
              width: diameter,
              height: diameter,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                  color: color.withValues(alpha: 0.9),
                  width: compact ? 2.5 : 3,
                ),
                boxShadow: const [
                  BoxShadow(color: Colors.black38, blurRadius: 3),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Toggles a task-event's completion straight from its calendar tag.
  /// Sets [_suppressTap] so the calendar's own tap handler doesn't also
  /// pop open the detail sheet (same trick the resize handles use).
  void _suppressNextTap() {
    _suppressTap = true;
    _resetSuppressSoon();
  }

  bool _isMovable(PlannerEvent event) {
    if (isReportDisplayId(event.id)) return false;
    if (isReportLaneId(event.id)) return false;
    if (isNodeBlockId(event.id)) return true;
    if (!event.isFromFeed) return event.recurrenceRule.isEmpty;
    if (!mounted) return false;
    return context.read<FeedCubit>().isRemoteEditable(event);
  }

  /// Set-based variant used by tiles: O(1) instead of an O(F) `byId` scan
  /// per tile per frame.
  bool _isMovableFast(PlannerEvent event, Set<String> remoteEditableFeedIds) {
    if (isReportDisplayId(event.id)) return false;
    if (isReportLaneId(event.id)) return false;
    if (isNodeBlockId(event.id)) return true;
    if (!event.isFromFeed) return event.recurrenceRule.isEmpty;
    final feedId = event.feedId;
    if (feedId == null || event.sourceUid == null) return false;
    return remoteEditableFeedIds.contains(feedId);
  }

  /// Toggl-style play/stop badge pinned to the tile's top-right corner.
  /// Unlike an in-row icon it never shrinks with the title text and it
  /// sits above the resize handles, so it stays tappable when selected.
  /// Deliberately chromeless (plain triangle, no bubble): it matches the
  /// white tile text instead of looking like a sticker.
  /// Node-backed events drive the node timer, plain events drive the
  /// event timer. The tap is suppressed so the calendar doesn't also pop
  /// open the detail sheet (same trick as the checkbox/handles).
  Widget _tilePlayBadge(PlannerEvent event, {Node? backing, bool? tracking}) {
    final isTracking = tracking ?? backing?.isTracking ?? event.isTracking;
    // NB: no onDoubleTapDown here (unlike the checkbox/resize pattern).
    // Adding any double-tap callback makes the framework hold every tap
    // for the double-tap timeout, delaying the toggle ~300ms — and in
    // widget tests the pending tap never resolves at all. A double-tap
    // on the badge just toggles twice (a no-op blip); onTapDown already
    // suppresses the calendar tap for both presses.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _suppressNextTap(),
      onTap: () => _toggleTileTracking(event, backing),
      child: Tooltip(
        message: isTracking ? 'Stop recording' : 'Start recording',
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(
            isTracking ? Icons.stop : Icons.play_arrow,
            size: 18,
            color: isTracking ? const Color(0xFFFF5252) : Colors.white,
          ),
        ),
      ),
    );
  }

  /// Node backing a calendar event, if any (same triple-match the detail
  /// sheet uses). Null for plain events.
  Node? _backingNodeFor(
    BuildContext context,
    PlannerEvent event, {
    Map<String, Node>? nodeByEventId,
    Map<String, Node>? nodeById,
  }) {
    // Fast path: hoisted maps from the outer builder (no watch, O(1)).
    if (nodeByEventId != null) {
      final hit =
          nodeByEventId[event.id] ??
          (event.taskId == null ? null : nodeByEventId['task:${event.taskId}']);
      if (hit != null) return hit;
      if (nodeById != null && event.taskId != null) {
        return nodeById[event.taskId];
      }
      return null;
    }
    try {
      // Indexed O(1) lookup via the cubit (no linear scan).
      final cubit = context.read<NodeCubit>();
      final hit = cubit.nodeForCalendarEvent(event.id);
      if (hit != null) return hit;
      final list = cubit.nodesForEventId(event.id);
      if (list.isNotEmpty) return list.first;
      if (event.taskId != null) return cubit.byId(event.taskId!);
    } catch (_) {}
    return null;
  }

  /// O(1) tracking check from hoisted sets (no per-tile cubit scans).
  bool? _tileTrackingFor(
    PlannerEvent event, {
    Map<String, Node>? nodeByEventId,
    Map<String, Node>? nodeById,
    Set<String>? trackingNodeIds,
    Set<String>? trackingEventIds,
  }) {
    if (trackingEventIds != null && trackingEventIds.contains(event.id)) {
      return true;
    }
    Node? backing;
    if (nodeByEventId != null) {
      backing =
          nodeByEventId[event.id] ??
          (event.taskId == null ? null : nodeByEventId['task:${event.taskId}']);
      backing ??= event.taskId == null ? null : nodeById?[event.taskId!];
    }
    if (backing != null) {
      if (trackingNodeIds != null) return trackingNodeIds.contains(backing.id);
      return backing.isTracking;
    }
    if (trackingEventIds != null) return false;
    return null;
  }

  void _toggleTileTracking(PlannerEvent event, Node? backing) {
    if (backing != null) {
      if (backing.isTracking) {
        stopNodeAndFinish(context, backing.id);
      } else {
        if (backing.isDone) return;
        try {
          NodeEventLink.startNodeTracking(
            context.read<NodeCubit>(),
            context.read<CalendarCubit>(),
            backing.id,
          );
        } catch (_) {}
      }
      return;
    }
    NodeCubit? nodes;
    CalendarCubit calendar;
    try {
      nodes = context.read<NodeCubit>();
      calendar = context.read<CalendarCubit>();
    } catch (_) {
      return;
    }
    final live = calendar.byId(event.id) ?? event;
    if (live.isTracking) {
      NodeEventLink.stopEventTrackingAligned(nodes, calendar, live.id);
    } else {
      if (live.allDay) return;
      NodeEventLink.startEventTracking(nodes, calendar, live.id);
    }
  }

  /// Checkbox for a calendar block: node blocks toggle the node itself,
  /// real events use the event/node link.
  Widget _blockCheckbox({
    required PlannerEvent event,
    required double size,
    required Color doneColor,
    Map<String, Node>? nodeById,
    Map<String, Node>? nodeByEventId,
    PlannerEvent? liveEvent,
  }) {
    if (isNodeBlockId(event.id)) {
      Node? node;
      try {
        final id = nodeIdFromBlockId(event.id);
        node = nodeById?[id] ?? context.read<NodeCubit>().byId(id);
      } catch (_) {}
      if (node != null) {
        return NodeCheckbox(node: node, size: size, doneColor: doneColor);
      }
    }
    // Pre-resolve backing from hoisted maps so the checkbox itself needs
    // no cubit subscription (it used to watch both cubits per tile).
    Node? backing;
    if (nodeByEventId != null || nodeById != null) {
      backing =
          nodeByEventId?[event.id] ??
          (event.taskId == null
              ? null
              : nodeByEventId?['task:${event.taskId}']) ??
          (event.taskId == null ? null : nodeById?[event.taskId!]);
    }
    PlannerEvent? live = liveEvent;
    live ??= (() {
      try {
        return context.read<CalendarCubit>().byId(event.id);
      } catch (_) {
        return null;
      }
    }());
    return EventNodeCheckbox(
      event: event,
      size: size,
      doneColor: doneColor,
      backing: backing,
      liveEvent: live,
    );
  }

  Future<void> _commitReschedule(
    PlannerEvent previous,
    PlannerEvent updated,
  ) async {
    if (updated.start == previous.start && updated.end == previous.end) {
      return;
    }
    final undoCubit = context.read<UndoCubit>();
    // A committed move is newer than the open edit form (native drag path):
    // drop its stale preview so the tile shows the committed times.
    // Callers repaint after this returns.
    _editPreview = null;
    if (isNodeBlockId(previous.id)) {
      Node? node;
      try {
        node = context.read<NodeCubit>().byId(nodeIdFromBlockId(previous.id));
      } catch (_) {}
      if (node == null) return;
      final s = node.schedule;
      context.read<NodeCubit>().updateNode(
        node.copyWith(
          schedule: ScheduleFacet(
            due: s?.due,
            start: updated.start,
            end: updated.end,
            allDay: updated.allDay,
            isFixed: s?.isFixed ?? false,
          ),
        ),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_movedText(updated)),
          action: SnackBarAction(label: 'Undo', onPressed: undoCubit.undo),
        ),
      );
      return;
    }
    final calendarCubit = context.read<CalendarCubit>();
    final nodesCubit = context.read<NodeCubit>();
    final messenger = ScaffoldMessenger.of(context);
    NodeEventSync.rescheduleLinkedEvent(calendarCubit, nodesCubit, updated);
    if (updated.reminderMinutesBefore == null) {
      unawaited(EventReminderService.cancelReminder(updated.id));
    } else {
      unawaited(EventReminderService.scheduleReminder(updated));
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(_movedText(updated)),
        action: SnackBarAction(label: 'Undo', onPressed: undoCubit.undo),
      ),
    );
    if (!previous.isFromFeed) return;
    // Optimistic: the new time is already applied above so the drop
    // feels instant. Push in the background; on failure revert.
    final error = await context.read<FeedCubit>().pushEventUpdate(updated);
    if (!mounted) return;
    if (error != null) {
      NodeEventSync.rescheduleLinkedEvent(calendarCubit, nodesCubit, previous);
      if (previous.reminderMinutesBefore == null) {
        unawaited(EventReminderService.cancelReminder(previous.id));
      } else {
        unawaited(EventReminderService.scheduleReminder(previous));
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  String _movedText(PlannerEvent event) {
    if (event.allDay) {
      return 'Moved to ${_calendarDayFormat.format(event.start)}';
    }
    return 'Moved to ${_calendarMoveFormat.format(event.start)}';
  }

  String _blockedMessage(PlannerEvent event) {
    return 'Synced and repeating events can’t be moved by dragging — '
        'open the event to edit it instead.';
  }

  void _onHandleDragStart(PlannerEvent event, bool top, double pxPerMinute) {
    _suppressTap = true;
    _handleOriginal = event;
    _handleTop = top;
    _handleDy = 0;
    _handlePxPerMinute = pxPerMinute <= 0 ? 1 : pxPerMinute;
    _resizePreview = event;
  }

  void _onHandleDragUpdate(DragUpdateDetails details) {
    final original = _handleOriginal;
    if (original == null) return;
    _handleDy += details.delta.dy;
    final minutes = _handleDy / _handlePxPerMinute;
    final shifted = (_handleTop ? original.start : original.end).add(
      Duration(microseconds: (minutes * 60000000).round()),
    );
    final snap = context.read<SettingsCubit>().state.snapMinutes;
    final preview = resizeEvent(
      original,
      _handleTop ? shifted : null,
      _handleTop ? null : shifted,
      snapMinutes: snap,
    );
    setState(() => _resizePreview = preview);
  }

  Future<void> _onHandleDragEnd() async {
    final original = _handleOriginal;
    final preview = _resizePreview;
    _handleOriginal = null;
    _resizePreview = null;
    if (original != null && preview != null) {
      if (original.id == calendarDraftEventId) {
        _updateDraftFromCalendar(preview);
        return;
      }
      // A committed drag is newer than the open edit form: drop its stale
      // preview so the tile shows the committed times.
      _editPreview = null;
      setState(() {});
      await _commitReschedule(original, preview);
    } else {
      setState(() {});
    }
    _resetSuppressSoon();
  }

  void _onHandleDragCancel() {
    _handleOriginal = null;
    _resizePreview = null;
    setState(() {});
    _resetSuppressSoon();
  }

  Widget _noReportHint() {
    return const Center(
      child: Card(
        margin: EdgeInsets.only(bottom: 24, left: 24, right: 24),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(
            'No reported time yet — start a timer or accept an auto-report.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }

  Color _eventColor(PlannerEvent event, Map<String, Color> feedColors) {
    return calendarEventColor(event, feedColors);
  }

  Widget _buildSidePanel(int snap) {
    return CalendarSidePanel(
      mode: _panelMode,
      snapMinutes: snap,
      selectedEventId: _selectedEventId,
      draft: _draftEvent,
      seedSubject: _draftSeedSubject,
      seedNotes: _draftSeedNotes,
      seedLocation: _draftSeedLocation,
      seedClassLabel: _draftSeedClassLabel,
      seedTaskId: _draftSeedTaskId,
      tasksContent: TasksPanel(onTaskTap: _selectTaskOnCalendar),
      onDraftChanged: _onDraftChanged,
      onEditChanged: _onEditChanged,
      onCreatingFinished: (saved) => _finishCreating(saved: saved),
      onEditingFinished: _finishEditing,
      onEditingCancelled: () => setState(() {
        _panelMode = CalendarPanelMode.detail;
        _editPreview = null;
      }),
      onEditRequested: () =>
          setState(() => _panelMode = CalendarPanelMode.editing),
      onBack: _backFromPanel,
      onClose: _closeDrawer,
      onReport: _reportEvent,
    );
  }

  void _onAddPressed() {
    if (_panelMode == CalendarPanelMode.creating && _draftEvent != null) {
      return;
    }
    final selected = _controller.selectedDate ?? DateTime.now();
    _openCreator(initialDate: selected);
  }

  /// Opens a node schedule block in the node editor.
  void _openNodeBlock(String blockId) {
    Node? node;
    try {
      node = context.read<NodeCubit>().byId(nodeIdFromBlockId(blockId));
    } catch (_) {}
    if (node == null || !mounted) return;
    showNodeEditor(context, existing: node);
  }

  void _openDetail(PlannerEvent event) {
    if (!_isWide) {
      if (_selectedEventId != null) {
        setState(() => _selectedEventId = null);
      }
      showEventDetail(
        context,
        event: event,
        onReport: event.isTask ? () => _reportEvent(event) : null,
      );
      return;
    }
    setState(() {
      _selectedEventId = event.id;
      _panelMode = CalendarPanelMode.detail;
      _panelOpen = true;
      _editPreview = null;
      _clearDraft();
    });
  }

  /// Panel task tap: highlights the task's calendar entry, navigating the
  /// calendar to its day, without replacing the task list. The node menu
  /// stays one tap away in the tile's ⋮ menu. Falls back to the node's own
  /// schedule block; when the task isn't on the calendar yet, points at
  /// the schedule control instead of failing silently.
  void _selectTaskOnCalendar(Node node) {
    final calendar = context.read<CalendarCubit>();
    PlannerEvent? target;
    for (final id in [node.calendarEventId, node.sourceEventId]) {
      if (id == null) continue;
      final linked = calendar.byId(id);
      if (linked != null) {
        target = linked;
        break;
      }
    }
    if (target == null) {
      // No direct link: prefer the next upcoming occurrence, then the
      // earliest one, so seeded events and old series land usefully.
      final now = DateTime.now();
      PlannerEvent? next;
      PlannerEvent? earliest;
      for (final event in calendar.state) {
        if (event.taskId != node.id) continue;
        if (event.start.isBefore(now)) {
          if (earliest == null || event.start.isBefore(earliest.start)) {
            earliest = event;
          }
        } else if (next == null || event.start.isBefore(next.start)) {
          next = event;
        }
      }
      target = next ?? earliest;
    }
    final schedule = node.schedule;
    final blockStart = target == null && (schedule?.hasCalendarBlock ?? false)
        ? schedule!.start
        : null;
    if (target == null && blockStart == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text('Not on the calendar yet'),
            duration: const Duration(seconds: 4),
            // Action snackbars persist forever by default; this one must go.
            persist: false,
            action: SnackBarAction(
              label: 'Schedule',
              onPressed: () => showScheduleSheet(context, nodeId: node.id),
            ),
          ),
        );
      return;
    }
    final start = target?.start ?? blockStart!;
    setState(() {
      _selectedEventId = target?.id ?? nodeBlockId(node.id);
      _editPreview = null;
    });
    _controller.displayDate = start;
  }

  void _setSideBySide(bool value) {
    if (_sideBySide == value) return;
    setState(() => _sideBySide = value);
    if (value) {
      _liveTicker ??= Timer.periodic(const Duration(seconds: 30), (_) {
        if (!mounted) return;
        setState(() {});
      });
    } else {
      _liveTicker?.cancel();
      _liveTicker = null;
    }
  }

  /// Jumps the calendar back to today, keeping the current Day/Week/Month
  /// view. Reached by re-tapping the active view segment (empty selection
  /// or same value): no double-tap detector, so view switches stay instant.
  void _goToToday() {
    final now = DateTime.now();
    _controller.displayDate = now;
    _controller.selectedDate = now;
  }

  /// Creates (or reuses) the manual report entry for a task-event,
  /// switches the calendar to the Plan + Report view, and opens the
  /// entry in the same time-editing UI as the day-review screen.
  Future<void> _reportEvent(PlannerEvent event) async {
    _setSideBySide(true);
    final reporting = context.read<ReportingCubit>();
    final existing = findReportEntryForEvent(reporting.state, event.id);
    final entry = existing ?? buildManualReportForEvent(event);
    final day = DateTime(entry.start.year, entry.start.month, entry.start.day);
    if (existing == null) {
      reporting.upsertEntry(day, entry);
    }
    if (!mounted) return;
    final saved = findReportEntryForEvent(reporting.state, event.id) ?? entry;
    await showReportedEditor(context, day: day, entry: saved);
  }

  void _openReport(String displayId) {
    final calendar = context.read<CalendarCubit>();
    ReportedEntry? entry;
    try {
      entry = findReportEntryByDisplayId(
        context.read<ReportingCubit>().state,
        displayId,
      );
    } catch (_) {}
    var eventId = entry?.eventId;
    if (eventId == null) {
      const timerPrefix = 'report:timer:';
      const livePrefix = 'report:live:';
      if (displayId.startsWith(timerPrefix)) {
        eventId = displayId.substring(timerPrefix.length);
      } else if (displayId.startsWith(livePrefix)) {
        eventId = displayId.substring(livePrefix.length);
      }
    }
    if (eventId != null) {
      final event = calendar.byId(eventId);
      if (event != null) {
        _openDetail(event);
        return;
      }
    }
    if (entry != null && mounted) {
      final start = entry.start;
      showReportedEditor(
        context,
        day: DateTime(start.year, start.month, start.day),
        entry: entry,
      );
    }
  }

  PlannerEvent _asDraft(PlannerEvent event) => PlannerEvent(
    id: calendarDraftEventId,
    subject: event.subject,
    notes: event.notes,
    location: event.location,
    start: event.start,
    end: event.end,
    allDay: event.allDay,
    recurrenceRule: event.recurrenceRule,
    classLabel: event.classLabel,
    colorValue: event.colorValue,
    taskId: event.taskId,
    isTask: event.isTask,
    done: event.done,
    completedAt: event.completedAt,
    placeId: event.placeId,
  );

  PlannerEvent _initialDraft({
    DateTime? initialDate,
    TimeOfDay? initialTime,
    TimeOfDay? initialEndTime,
    String? subject,
    String? notes,
    String? location,
    String? classLabel,
  }) {
    final snap = context.read<SettingsCubit>().state.snapMinutes;
    final base = initialDate ?? DateTime.now();
    final day = DateTime(base.year, base.month, base.day);
    final DateTime start;
    if (initialTime != null) {
      start = snapToInterval(
        DateTime(
          day.year,
          day.month,
          day.day,
          initialTime.hour,
          initialTime.minute,
        ),
        snap,
      );
    } else {
      start = DateTime(day.year, day.month, day.day, 9);
    }
    var end = initialEndTime == null
        ? start.add(const Duration(hours: 1))
        : snapToInterval(
            DateTime(
              day.year,
              day.month,
              day.day,
              initialEndTime.hour,
              initialEndTime.minute,
            ),
            snap,
          );
    if (!end.isAfter(start)) end = start.add(const Duration(hours: 1));
    return PlannerEvent(
      id: calendarDraftEventId,
      subject: subject ?? '',
      notes: notes,
      location: location,
      start: start,
      end: end,
      classLabel: classLabel,
    );
  }

  void _focusOnDraft(DateTime date) {
    _controller.displayDate = date;
    _controller.selectedDate = date;
  }

  void _openCreator({
    DateTime? initialDate,
    TimeOfDay? initialTime,
    PlannerEvent? seed,
  }) {
    final draft = seed != null
        ? _asDraft(seed)
        : _initialDraft(initialDate: initialDate, initialTime: initialTime);
    _focusOnDraft(draft.start);
    if (!_isWide) {
      _openSheetCreator(draft);
      return;
    }
    setState(() {
      _selectedEventId = null;
      _panelMode = CalendarPanelMode.creating;
      _panelOpen = true;
      _draftEvent = draft;
      _draftSeedSubject = seed?.subject;
      _draftSeedNotes = seed?.notes;
      _draftSeedLocation = seed?.location;
      _draftSeedClassLabel = seed?.classLabel;
      _draftSeedTaskId = seed?.taskId;
    });
  }

  Future<void> _openSheetCreator(PlannerEvent draft) async {
    setState(() {
      _selectedEventId = null;
      _panelMode = CalendarPanelMode.creating;
      _draftEvent = draft;
      _draftSeedSubject = draft.subject.isEmpty ? null : draft.subject;
      _draftSeedNotes = draft.notes;
      _draftSeedLocation = draft.location;
      _draftSeedClassLabel = draft.classLabel;
      _draftSeedTaskId = draft.taskId;
    });
    final saved = await showEventEditor(
      context,
      initialDate: DateTime(
        draft.start.year,
        draft.start.month,
        draft.start.day,
      ),
      initialTime: draft.allDay ? null : TimeOfDay.fromDateTime(draft.start),
      initialEndTime: draft.allDay ? null : TimeOfDay.fromDateTime(draft.end),
      initialSubject: _draftSeedSubject,
      initialNotes: _draftSeedNotes,
      initialLocation: _draftSeedLocation,
      initialClassLabel: _draftSeedClassLabel,
      initialTaskId: _draftSeedTaskId,
      onDraftChanged: _onDraftChanged,
    );
    if (!mounted) return;
    _finishCreating(saved: saved == true);
  }

  void _onDraftChanged(PlannerEvent draft) {
    if (!mounted) return;
    final previous = _draftEvent;
    setState(() => _draftEvent = _asDraft(draft));
    if (previous == null ||
        previous.start.year != draft.start.year ||
        previous.start.month != draft.start.month ||
        previous.start.day != draft.start.day) {
      _focusOnDraft(draft.start);
    }
  }

  /// Edit-form twin of [_onDraftChanged]: the editing drawer owns its
  /// field state until Save, so the form pushes a preview here and the
  /// calendar tile tracks the sidebar live.
  void _onEditChanged(PlannerEvent preview) {
    if (!mounted) return;
    final previous = _editPreview;
    setState(() => _editPreview = preview);
    if (previous == null ||
        previous.start.year != preview.start.year ||
        previous.start.month != preview.start.month ||
        previous.start.day != preview.start.day) {
      _focusOnDraft(preview.start);
    }
  }

  void _updateDraftFromCalendar(PlannerEvent updated) {
    if (!mounted) return;
    setState(() => _draftEvent = _asDraft(updated));
    _controller.selectedDate = updated.start;
  }

  void _clearDraft() {
    _draftEvent = null;
    _draftSeedSubject = null;
    _draftSeedNotes = null;
    _draftSeedLocation = null;
    _draftSeedClassLabel = null;
    _draftSeedTaskId = null;
  }

  void _closeDrawer() {
    setState(() {
      _panelOpen = false;
      _panelMode = CalendarPanelMode.tasks;
      _selectedEventId = null;
      _editPreview = null;
      _seedFromPageMount = false;
      _clearDraft();
    });
  }

  /// Opens the panel (task list) or closes it entirely. Reached from the
  /// toolbar toggle (wide screens only).
  void _togglePanel() {
    if (_panelOpen) {
      _closeDrawer();
    } else {
      setState(() => _panelOpen = true);
    }
  }

  /// Header back arrow: leaves whatever the panel is showing for the task
  /// list. A draft in progress is cancelled; an open edit falls back to the
  /// event's detail. Closing the panel entirely stays on the ✕ / toggle.
  void _backFromPanel() {
    switch (_panelMode) {
      case CalendarPanelMode.creating:
        _finishCreating(saved: false);
      case CalendarPanelMode.editing:
        setState(() {
          _panelMode = CalendarPanelMode.detail;
          _editPreview = null;
        });
      case CalendarPanelMode.detail:
      case CalendarPanelMode.tasks:
        setState(() {
          _panelMode = CalendarPanelMode.tasks;
          _selectedEventId = null;
          _editPreview = null;
          _clearDraft();
        });
    }
  }

  /// Finishes the edit form: back to the event's detail when it still
  /// exists, panel closed when it was deleted while editing.
  void _finishEditing() {
    final id = _selectedEventId;
    final stillThere = id == null
        ? null
        : context.read<CalendarCubit>().byId(id);
    if (stillThere == null) {
      _closeDrawer();
    } else {
      setState(() {
        _panelMode = CalendarPanelMode.detail;
        _editPreview = null;
      });
    }
  }

  /// Closes the create flow and falls back to the panel's task list. When
  /// the draft was claimed as this page mounted (Tasks → Pick time on
  /// calendar) and was actually saved, returns to Tasks so the next
  /// assignment can be scheduled without extra taps; plain calendar
  /// creates, cancelled drafts, and seeds delivered while the page was
  /// already open (the side panel's own schedule flow) stay here.
  void _finishCreating({required bool saved}) {
    final taskId = _draftSeedTaskId;
    final returnsToTasks =
        _seedFromPageMount && saved && taskId != null && taskId.isNotEmpty;
    _seedFromPageMount = false;
    if (!mounted) return;
    setState(() {
      _panelMode = CalendarPanelMode.tasks;
      _selectedEventId = null;
      _editPreview = null;
      _clearDraft();
    });
    if (returnsToTasks) {
      try {
        context.read<NavigationCubit>().setPage(PlannerPage.tasks);
      } catch (_) {}
    }
  }

  void _onTap(CalendarTapDetails details) {
    if (_suppressTap) return;
    if (details.targetElement == CalendarElement.appointment) {
      final raw = details.appointments?.isNotEmpty ?? false
          ? details.appointments!.first
          : null;
      if (raw is PlannerEvent && raw.id == calendarDraftEventId) return;
      // Lane placeholder taps (the empty part of a report column) are not
      // events; the chips handle their own taps.
      if (raw is PlannerEvent && isReportLaneId(raw.id)) return;
      if (raw is PlannerEvent && isReportDisplayId(raw.id)) {
        _openReport(raw.id);
        return;
      }
      if (raw is PlannerEvent && isNodeBlockId(raw.id)) {
        _openNodeBlock(raw.id);
        return;
      }
      final event = _resolveEvent(raw, details.date);
      if (event != null) {
        _openDetail(event);
      }
      return;
    }
    if (details.targetElement == CalendarElement.calendarCell &&
        details.date != null) {
      final date = details.date!;
      final tappedMidnight = date.hour == 0 && date.minute == 0;
      if (_panelMode == CalendarPanelMode.creating && _draftEvent != null) {
        _moveDraftTo(date, keepTimeOfDay: tappedMidnight);
        return;
      }
      _openCreator(
        initialDate: date,
        initialTime: tappedMidnight
            ? null
            : TimeOfDay(hour: date.hour, minute: date.minute),
      );
    }
  }

  void _moveDraftTo(DateTime date, {required bool keepTimeOfDay}) {
    final draft = _draftEvent;
    if (draft == null) return;
    final snap = context.read<SettingsCubit>().state.snapMinutes;
    final PlannerEvent updated;
    if (keepTimeOfDay && !draft.allDay) {
      final duration = draft.end.isAfter(draft.start)
          ? draft.end.difference(draft.start)
          : const Duration(hours: 1);
      final start = snapToInterval(
        DateTime(
          date.year,
          date.month,
          date.day,
          draft.start.hour,
          draft.start.minute,
        ),
        snap,
      );
      updated = draft.copyWith(start: start, end: start.add(duration));
    } else {
      updated = shiftEvent(draft, date, snapMinutes: snap);
    }
    _updateDraftFromCalendar(updated);
  }

  void _onDragStart(AppointmentDragStartDetails details) {
    _isDragging = true;
    _suppressTap = true;
    if (_handleOriginal != null) {
      _ignoreNativeDragEnd = true;
    }
  }

  /// Keeps the creation ghost on screen while the user pages with the
  /// header arrows (or switches Day/Week/Month): when the draft day scrolls
  /// out of view, the ghost travels to the newly visible date, keeping its
  /// wall-clock time and duration so it can be dragged to its final slot.
  /// A mid-drag page turn is left to the native drop target instead.
  void _onViewChanged(ViewChangedDetails details) {
    if (_panelMode != CalendarPanelMode.creating) return;
    final draft = _draftEvent;
    if (draft == null || _isDragging) return;
    final snap = context.read<SettingsCubit>().state.snapMinutes;
    final traveled = travelGhostToVisible(
      draft,
      details.visibleDates,
      _controller.displayDate,
      snapMinutes: snap,
    );
    if (traveled != null) _updateDraftFromCalendar(traveled);
  }

  Future<void> _onDragEnd(AppointmentDragEndDetails details) async {
    _isDragging = false;
    if (_ignoreNativeDragEnd) {
      _ignoreNativeDragEnd = false;
      setState(() {});
      _resetSuppressSoon();
      return;
    }
    _resetSuppressSoon();
    // Every path below ends in a rebuild so the calendar always renders
    // from real data — a dropped block can never be left floating.
    try {
      final appointment = details.appointment;
      final droppingTime = details.droppingTime;
      if (appointment is PlannerEvent &&
          (isReportDisplayId(appointment.id) ||
              isReportLaneId(appointment.id))) {
        if (mounted) setState(() {});
        return;
      }
      if (appointment is PlannerEvent &&
          appointment.id == calendarDraftEventId) {
        final draft = _draftEvent;
        if (draft != null && droppingTime != null) {
          final snap = context.read<SettingsCubit>().state.snapMinutes;
          _updateDraftFromCalendar(
            shiftEvent(draft, droppingTime, snapMinutes: snap),
          );
        }
        return;
      }
      if (appointment is PlannerEvent && isNodeBlockId(appointment.id)) {
        if (droppingTime == null) {
          if (mounted) setState(() {});
          return;
        }
        Node? node;
        try {
          node = context.read<NodeCubit>().byId(
            nodeIdFromBlockId(appointment.id),
          );
        } catch (_) {}
        if (node == null || node.schedule?.hasCalendarBlock != true) {
          if (mounted) setState(() {});
          return;
        }
        final snap = context.read<SettingsCubit>().state.snapMinutes;
        final shifted = shiftEvent(
          appointment,
          droppingTime,
          snapMinutes: snap,
        );
        // Syncfusion already moved its callback object. Compare with the
        // stored schedule so a real node move is not mistaken for a no-op.
        final schedule = node.schedule!;
        await _commitReschedule(
          appointment.copyWith(start: schedule.start, end: schedule.end),
          shifted,
        );
        return;
      }
      if (appointment is! PlannerEvent || droppingTime == null) {
        if (mounted && appointment != null && appointment is! PlannerEvent) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Couldn’t move that event — please try again.'),
            ),
          );
        }
        return;
      }
      final event =
          context.read<CalendarCubit>().byId(appointment.id) ?? appointment;
      if (!_isMovable(event)) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(_blockedMessage(event))));
        }
        return;
      }
      final snap = context.read<SettingsCubit>().state.snapMinutes;
      final updated = shiftEvent(event, droppingTime, snapMinutes: snap);
      await _commitReschedule(event, updated);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn’t move that event — please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() {});
    }
  }

  PlannerEvent? _resolveEvent(Object? raw, DateTime? tappedDate) {
    if (raw is PlannerEvent) return raw;
    if (raw is Appointment && tappedDate != null) {
      final cubit = context.read<CalendarCubit>();
      final feedCubit = context.read<FeedCubit>();
      final visibility = context.read<CalendarVisibilityCubit>();
      final feedById = {for (final feed in feedCubit.state) feed.id: feed};
      // Set-based visibility (was O(F) byId per event); skip non-recurring
      // up front — only recurring series need occurrence expansion, and
      // expansion is the expensive part of this tap path.
      final enabled = feedCubit.enabledFeedIds;
      final dayStart = DateTime(
        tappedDate.year,
        tappedDate.month,
        tappedDate.day,
      );
      final dayEnd = dayStart.add(const Duration(days: 1));
      final candidates = <PlannerEvent>[];
      for (final event in cubit.state) {
        if (event.recurrenceRule.isEmpty) continue;
        final feedId = event.feedId;
        // Unknown feeds stay visible (matches isFeedVisible); only skip
        // known-but-disabled feeds.
        if (feedId != null &&
            feedById.containsKey(feedId) &&
            !enabled.contains(feedId)) {
          continue;
        }
        if (!visibility.isEventVisible(event, feedById)) continue;
        final occurrences = cubit.occurrencesOf(event, dayStart, dayEnd);
        if (occurrences.isEmpty) continue;
        final exact = occurrences.any(
          (o) => o.hour == tappedDate.hour && o.minute == tappedDate.minute,
        );
        if (exact) return event;
        candidates.add(event);
      }
      if (candidates.length == 1) return candidates.first;
    }
    return null;
  }
}

/// Watches for a running event timer and shows [_RecordingBanner] while
/// one is active. Collapses to nothing otherwise.
class _RecordingBannerSlot extends StatelessWidget {
  final ValueChanged<PlannerEvent> onOpen;

  const _RecordingBannerSlot({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    // Select only the active tracking event: rebuilds only when it changes,
    // not on every calendar emit (the old watch rebuilt on any event edit).
    return BlocSelector<CalendarCubit, List<PlannerEvent>, PlannerEvent?>(
      selector: (events) {
        for (final e in events) {
          if (e.isTracking) return e;
        }
        return null;
      },
      builder: (context, active) {
        if (active == null || active.timerStartedAt == null) {
          return const SizedBox.shrink();
        }
        return _RecordingBanner(event: active, onOpen: onOpen);
      },
    );
  }
}

class _RecordingBanner extends StatefulWidget {
  final PlannerEvent event;
  final ValueChanged<PlannerEvent> onOpen;

  const _RecordingBanner({required this.event, required this.onOpen});

  @override
  State<_RecordingBanner> createState() => _RecordingBannerState();
}

class _RecordingBannerState extends State<_RecordingBanner> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  static String _elapsed(DateTime since) {
    final d = DateTime.now().difference(since);
    final total = d.inSeconds < 0 ? 0 : d.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final startedAt = widget.event.timerStartedAt ?? widget.event.start;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => widget.onOpen(widget.event),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: BoxDecoration(
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.fiber_manual_record,
                size: 14,
                color: Color(0xFFFF5252),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Recording · ${_elapsed(startedAt)}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      widget.event.subject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () {
                  try {
                    NodeEventLink.stopEventTrackingAligned(
                      context.read<NodeCubit>(),
                      context.read<CalendarCubit>(),
                      widget.event.id,
                    );
                  } catch (_) {}
                },
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.stop, size: 16),
                label: const Text('Stop'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
