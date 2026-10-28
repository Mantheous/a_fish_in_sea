import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

import '../../common/time/local_date.dart';
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
import '../../reporting/bloc/reporting_cubit.dart';
import '../../reporting/model/reported_entry.dart';
import '../../reporting/view/day_review_screen.dart';
import '../bloc/calendar_cubit.dart';
import '../bloc/calendar_draft_cubit.dart';
import '../bloc/calendar_visibility_cubit.dart';
import '../bloc/feed_cubit.dart';
import '../model/color_prefs.dart';
import '../model/event_reschedule.dart';
import '../model/planner_event.dart';
import '../bloc/settings_cubit.dart';
import '../service/calendar_report.dart';
import '../service/event_reminders.dart';
import '../service/report_adjustment.dart';
import 'calendar_data_source.dart';
import 'calendar_grid_tracker.dart';
import 'calendar_projection.dart';
import 'calendar_filter_sheet.dart';
import 'calendar_report_layout.dart';
import 'calendar_recording_banner.dart';
import 'calendar_side_panel.dart';
import 'calendar_snackbars.dart';
import 'calendar_tile_metrics.dart';
import 'event_colors.dart';
import 'event_editor.dart';
import 'feed_manager.dart';
import 'plan_tile_drag.dart';
import 'plan_to_report_copy.dart';
import 'report_lane_overlay.dart';
import 'task_tile_helpers.dart';
import 'tasks_panel.dart';

const double _wideBreakpoint = 720;
const double _calendarTimeRulerWidth = 70;
const double _calendarViewHeaderHeight = 60;

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

  /// Report chip the user tapped in the Plan + Report lane. Its white
  /// resize circles adjust the reported interval; null when the selection
  /// belongs to a plan tile instead.
  String? _selectedReportId;

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
  // Selection held before opening the create flow, restored on cancel so
  // the calendar's selected-slot highlight (drawn from selectedDate) does
  // not linger on the draft's old slot.
  DateTime? _preCreateSelectedDate;
  bool _preCreateSelectionCaptured = false;
  String? _draftSeedSubject;
  String? _draftSeedNotes;
  String? _draftSeedLocation;
  String? _draftSeedClassLabel;
  String? _draftSeedTaskId;
  bool _suppressTap = false;
  bool _sideBySide = false;
  Timer? _liveTicker;
  Timer? _suppressTimer;
  Timer? _recordingTicker;
  StreamSubscription<List<Node>>? _nodeTickerSub;
  StreamSubscription<List<PlannerEvent>>? _calendarTickerSub;
  PlannerCalendarDataSource? _dataSource;
  final _projection = CalendarProjection();
  TimeSlotViewSettings? _slotSettingsCache;
  double? _slotStartHour;
  double? _slotEndHour;

  /// Where the plan calendar and the report overlay meet: the one grid's
  /// scroll offset and on-screen rect. The overlay only reads it.
  late final _gridTracker = PlanGridTracker(
    isMounted: () => mounted,
    timeGridViewportThreshold: _calendarViewHeaderHeight,
    anchorKey: _calendarStackKey,
  );

  /// The stack holding the calendar and its report overlay. The tracker
  /// reports grid geometry relative to it.
  final _calendarStackKey = GlobalKey(debugLabel: 'plan-calendar-stack');

  /// Wraps the plan calendar so the tracker can walk down to its time-grid
  /// scrollable (Syncfusion gives no public handle on it).
  final _calendarSubtreeKey = GlobalKey(debugLabel: 'plan-calendar-subtree');
  bool _gridDiscoveryScheduled = false;

  TimeSlotViewSettings _slotSettings(double startHour, double endHour) {
    if (_slotSettingsCache == null ||
        _slotStartHour != startHour ||
        _slotEndHour != endHour) {
      _slotSettingsCache = TimeSlotViewSettings(
        timeInterval: const Duration(minutes: 30),
        startHour: startHour,
        endHour: endHour,
        // Zero-duration events lay out at 0px without this: invisible and
        // untappable, though they still show in lists and the month agenda.
        // Every timed tile gets at least the app's minimum event span.
        minimumAppointmentDuration: minimumTileDuration,
        // Default is 'h a' (e.g. "9 AM"), which renders 9:00 and 9:30
        // identically. Include minutes so each 30-min line is distinct.
        timeFormat: 'h:mm a',
        // Wide enough for "12:30 PM" on one line (auto size wraps it).
        timeRulerSize: _calendarTimeRulerWidth,
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
  PlannerEvent? _pairedDragOriginal;
  Offset? _pairedDragOrigin;

  /// Latest pointer position of the tile drag. Kept so the auto-scroll ticker
  /// can recompute the drop time while the grid moves under a still pointer.
  Offset? _pairedDragPointer;
  DateTime? _pairedDragDropTime;

  /// Day column last under the pointer *inside* the grid. Dragging over the
  /// time ruler scrolls but keeps this day, so grabbing the ruler handle
  /// never throws the tile onto the first/last day of the week.
  DateTime? _pairedDragDay;
  List<DateTime> _pairedDragDays = const [];
  double _pairedDragCellWidth = 0;
  double _pairedDragPixelsPerMinute = 0;
  bool _pairedDragIsRtl = false;
  double _pairedDragScrollAtStart = 0;
  double _pairedDragStartMinutes = 0;
  double _pairedDragEndMinutes = 24 * 60;
  double _pairedDragDurationMinutes = 60;
  Timer? _pairedDragAutoScroll;

  bool get _isWide => MediaQuery.of(context).size.width >= _wideBreakpoint;
  bool _appliedNarrowDefault = false;

  /// Explicit Day/Week/Month switch: updates the visible calendar and keeps
  /// the choice as this device's local default (device-local, never synced —
  /// a phone stays on day while a desktop stays on week). The narrow-screen
  /// day forcing in [didChangeDependencies] stays ephemeral on purpose.
  void _setView(CalendarView view) {
    setState(() => _view = view);
    _controller.view = view;
    // Day ↔ Week rebuilds the calendar's time-grid scrollable; re-find it.
    _gridTracker.reset();
    _scheduleGridDiscovery();
    try {
      if (context.read<SettingsCubit>().state.defaultCalendarView != view) {
        context.read<SettingsCubit>().setDefaultCalendarView(view);
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _view = context.read<SettingsCubit>().state.defaultCalendarView;
    _controller.view = _view;
    _controller.addPropertyChangedListener(_onCalendarControllerChanged);
    _wireRecordingTicker();
    // Claim a pending seed before the first build. The projection only puts
    // a draft into the data source while the create flow is active, and a
    // post-frame claim added the ghost through an incremental
    // CalendarDataSourceAction.add after Syncfusion's initial layout — the
    // appointment existed in the data source but never got painted, so a
    // "schedule follow-up" landed on the calendar with no visible ghost.
    final pending = _takePendingDraft();
    if (pending != null) {
      _seedFromPageMount = true;
      final draft = _asDraft(pending);
      _applyCreatorState(draft, seed: pending);
      // The narrow-screen editor sheet needs a mounted Navigator; wide
      // screens show the create panel from the first frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isWide) return;
        _openSheetCreator(_draftEvent ?? draft);
      });
    }
  }

  PlannerEvent? _takePendingDraft() {
    try {
      return context.read<CalendarDraftCubit>().takePending();
    } catch (_) {
      return null;
    }
  }

  /// Refreshes the live recording block's end time while a timer runs.
  /// Without this the Calendar would freeze the block at its first frame
  /// even though the banner's elapsed clock keeps moving.
  void _wireRecordingTicker() {
    try {
      final nodes = context.read<NodeCubit>();
      final calendar = context.read<CalendarCubit>();
      _syncRecordingTicker(nodes.state, calendar.state);
      _nodeTickerSub = nodes.stream.listen((value) {
        _syncRecordingTicker(value, calendar.state);
      });
      _calendarTickerSub = calendar.stream.listen((value) {
        _syncRecordingTicker(nodes.state, value);
      });
    } catch (_) {
      // Standalone widget tests may mount the page without both cubits;
      // the rest of the page has the same tolerance.
    }
  }

  void _syncRecordingTicker(List<Node> nodes, List<PlannerEvent> events) {
    final active =
        nodes.any((node) => node.isTracking) ||
        events.any((event) => event.isTracking);
    if (active && _recordingTicker == null) {
      _recordingTicker = Timer.periodic(const Duration(seconds: 15), (_) {
        if (mounted) setState(() {});
      });
    } else if (!active && _recordingTicker != null) {
      _recordingTicker?.cancel();
      _recordingTicker = null;
    }
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
      // A pending seed claims the create flow in initState; the panel
      // default must not close it on the first dependency pass.
      _panelOpen =
          _panelMode == CalendarPanelMode.creating ||
          MediaQuery.of(context).size.width >= _panelDefaultBreakpoint;
    }
  }

  @override
  void dispose() {
    _liveTicker?.cancel();
    _suppressTimer?.cancel();
    _recordingTicker?.cancel();
    _pairedDragAutoScroll?.cancel();
    _nodeTickerSub?.cancel();
    _calendarTickerSub?.cancel();
    _controller.removePropertyChangedListener(_onCalendarControllerChanged);
    _dataSource?.dispose();
    _gridTracker.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Navigation happens inside SfCalendar (header arrows, swipes). The
  /// report overlay is derived from the same controller, so a navigation
  /// only needs a rebuild; the tracker also re-finds the time grid because
  /// Day ↔ Week swaps the scrollable underneath it.
  void _onCalendarControllerChanged(String property) {
    _scheduleGridDiscovery();
    if (!_sideBySide || _view == CalendarView.month) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  /// Finds the plan calendar's time-grid scrollable once the frame is laid
  /// out. Deferred (and de-duplicated) because discovery runs during build:
  /// the calendar's own subtree is only complete at frame end.
  void _scheduleGridDiscovery() {
    if (_gridDiscoveryScheduled) return;
    _gridDiscoveryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gridDiscoveryScheduled = false;
      if (!mounted) return;
      final rootContext = _calendarSubtreeKey.currentContext;
      if (rootContext == null) return;
      _gridTracker.discover(rootContext);
      _gridTracker.refreshViewport();
    });
  }

  static const Key _planCalendarKey = Key('plan-calendar');

  /// The days the report overlay must cover: what the calendar shows right
  /// now — the display date in the day view, its Sunday-start week in the
  /// week view. Lanes only exist while the Plan + Report view is on and a
  /// time-slot grid is visible (the month view keeps its agenda chips).
  List<DateTime> _visibleDaysForLane() {
    final display = _controller.displayDate ?? DateTime.now();
    final day = localDay(display);
    if (_view == CalendarView.day) return [day];
    // Back up to the week's first day per the firstDayOfWeek setting.
    final firstDayOfWeek = context.read<SettingsCubit>().state.firstDayOfWeek;
    final startOffset = (day.weekday - firstDayOfWeek + 7) % 7;
    final start = shiftLocalDay(day, -startOffset);
    return [for (var i = 0; i < 7; i++) shiftLocalDay(start, i)];
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
                            _setView(selection.first);
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
                                _setView(selection.first);
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
                  'Each day: plan on the left, report right beside it · '
                  'tap ⧉ on a plan to copy it to the report · '
                  'tap a report for details and ▶ to record it again · '
                  'drag its circles to adjust · red = recording now',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            // Toggl-style running-entry bar: always visible while an event
            // timer is recording, with elapsed time and Stop.
            RecordingBannerSlot(
              onOpen: (recording) {
                final nodeId = recording.nodeId;
                if (nodeId != null) {
                  final node = context.read<NodeCubit>().byId(nodeId);
                  if (node != null) showNodeEditor(context, existing: node);
                  return;
                }
                final eventId = recording.eventId;
                if (eventId == null) return;
                PlannerEvent? live;
                try {
                  live = context.read<CalendarCubit>().byId(eventId);
                } catch (_) {
                  live = null;
                }
                if (live != null) _openDetail(live);
              },
            ),
            Expanded(
              child: BlocBuilder<CalendarCubit, List<PlannerEvent>>(
                builder: (context, events) {
                  final sideBySide = _sideBySide;
                  final wide = _isWide;
                  final reportLanes = sideBySide && _view != CalendarView.month;
                  final laneDays = reportLanes
                      ? _visibleDaysForLane()
                      : const <DateTime>[];
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
                    visibleDays: laneDays,
                    visibleStartHour: settings.dayStartHour,
                    visibleEndHour: settings.dayEndHour,
                    now: DateTime.now(),
                    colorPrefs: settings.colors,
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
                  final reportById = _projection.reportById;
                  if (_dataSource == null) {
                    _dataSource = PlannerCalendarDataSource(
                      shown,
                      feedColors,
                      colorById,
                      settings.colors,
                    );
                  } else if (!_dataSource!.matches(
                    shown,
                    feedColors,
                    colorById,
                  )) {
                    _dataSource!.update(shown, feedColors, colorById);
                  }
                  // Track the time grid in both Plans and Plan + Report: the
                  // drag needs its scroll offset and viewport to auto-scroll
                  // the ruler, and the report overlay reads the same geometry.
                  if (_view != CalendarView.month) _scheduleGridDiscovery();
                  // Keep the calendar at a stable tree position. Opening a
                  // drawer or report hint must not dispose/recreate SfCalendar
                  // and regenerate every appointment (or leave its scheduled
                  // data-source callbacks pointing at a disposed state).
                  //
                  // Plans are drawn in the leading half of each day cell and
                  // the report overlay paints the trailing half. One calendar
                  // owns every gesture; the overlay only mirrors its scroll.
                  final calendarView = LayoutBuilder(
                    builder: (context, constraints) {
                      final isRtl = Directionality.of(context).name == 'rtl';
                      final headerHeight = compactHeader ? 32.0 : 40.0;
                      final slotSettings = _slotSettings(
                        settings.dayStartHour,
                        settings.dayEndHour,
                      );
                      // Day columns for tile drags: the side-by-side view
                      // already knows them; Plans mode derives the same grid
                      // from the controller so both modes can drop on a day.
                      final dayColumns = laneDays.isNotEmpty
                          ? laneDays
                          : _visibleDaysForLane();
                      final dragCellWidth = dayColumns.isEmpty
                          ? 0.0
                          : (constraints.maxWidth - _calendarTimeRulerWidth) /
                                dayColumns.length;
                      final pixelsPerMinute =
                          slotSettings.timeIntervalHeight /
                          slotSettings.timeInterval.inMinutes;
                      final calendar = SfCalendar(
                        key: _planCalendarKey,
                        controller: _controller,
                        view: _view,
                        dataSource: _dataSource!,
                        firstDayOfWeek: settings.firstDayOfWeek,
                        allowDragAndDrop: true,
                        allowAppointmentResize: false,
                        dragAndDropSettings: const DragAndDropSettings(
                          allowNavigation: true,
                          allowScroll: true,
                          autoNavigateDelay: Duration(milliseconds: 500),
                          showTimeIndicator: true,
                        ),
                        appointmentBuilder: (context, details) {
                          final tile = _appointmentBuilder(
                            feedColors,
                            context,
                            details,
                            reportById: reportById,
                            colorById: colorById,
                            colorPrefs: settings.colors,
                            remoteEditableFeedIds:
                                _projection.remoteEditableFeedIds,
                            nodeById: _projection.nodeById,
                            nodeByEventId: _projection.nodeByEventId,
                            trackingNodeIds: _projection.trackingNodeIds,
                            trackingEventIds: _projection.trackingEventIds,
                            assigneeLabelById: _projection.assigneeLabelById,
                            reportedEventIds: _projection.reportedEventIds,
                            showCopyToReport: reportLanes,
                            dayColumns: dayColumns,
                            cellWidth: dragCellWidth,
                            pixelsPerMinute: pixelsPerMinute,
                            isRtl: isRtl,
                          );
                          final raw = details.appointments.isNotEmpty
                              ? details.appointments.first
                              : null;
                          final event = raw is PlannerEvent ? raw : null;
                          if (!reportLanes ||
                              details.isMoreAppointmentRegion ||
                              event == null) {
                            return tile;
                          }
                          return planAppointmentInTrack(
                            child: tile,
                            bounds: details.bounds,
                            day: details.date,
                            visibleDays: laneDays,
                            calendarWidth: constraints.maxWidth,
                            timeRulerWidth: _calendarTimeRulerWidth,
                            isRtl: isRtl,
                            eventId: event.id,
                            tracker: _gridTracker,
                            onTap: () {
                              if (_suppressTap ||
                                  event.id == calendarDraftEventId) {
                                return;
                              }
                              if (isReportDisplayId(event.id)) {
                                _openReport(event.id);
                              } else if (isNodeBlockId(event.id)) {
                                _openNodeBlock(event.id);
                              } else {
                                _openDetail(event);
                              }
                            },
                            onPointerSignal: _gridTracker.onPlanPointerSignal,
                            onVerticalDragUpdate:
                                _gridTracker.onPlanVerticalDrag,
                          );
                        },
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
                        timeSlotViewSettings: slotSettings,
                        todayHighlightColor: Theme.of(
                          context,
                        ).colorScheme.primary,
                        headerDateFormat: compactHeader ? 'MMM y' : null,
                        headerHeight: headerHeight,
                        viewHeaderHeight: _view == CalendarView.week
                            ? _calendarViewHeaderHeight
                            : -1,
                        headerStyle: compactHeader
                            ? const CalendarHeaderStyle(
                                textStyle: TextStyle(fontSize: 14),
                              )
                            : const CalendarHeaderStyle(),
                        showNavigationArrow: true,
                      );
                      final reportCalendar = reportLanes
                          ? Positioned.fill(
                              child: ReportLaneOverlay(
                                tracker: _gridTracker,
                                width: constraints.maxWidth,
                                days: laneDays,
                                startHour: settings.dayStartHour,
                                endHour: settings.dayEndHour,
                                pixelsPerMinute: pixelsPerMinute,
                                snapMinutes: snap,
                                timeRulerWidth: _calendarTimeRulerWidth,
                                isRtl: isRtl,
                                blocksForDay: (day) =>
                                    _projection.reportBlocksByDay[day] ??
                                    const <ReportBlock>[],
                                selectedId:
                                    _selectedReportBlock()?.displayId ??
                                    _selectedReportId,
                                onIntervalChanged: _adjustReportedInterval,
                                onRecord: _recordReport,
                                onDeleted: _deleteReportedBlock,
                                colorFor: (block) =>
                                    _projection.reportColorById[block
                                        .displayId] ??
                                    const Color(defaultPersonalEventColor),
                                onTap: (block) {
                                  _suppressNextTap();
                                  _openReport(block.displayId);
                                },
                              ),
                            )
                          : null;
                      return Stack(
                        key: _calendarStackKey,
                        children: [
                          Positioned.fill(
                            child: KeyedSubtree(
                              key: _calendarSubtreeKey,
                              child: NotificationListener<ScrollNotification>(
                                onNotification: _gridTracker.onPlanScroll,
                                child: calendar,
                              ),
                            ),
                          ),
                          if (reportCalendar != null) reportCalendar,
                          if (sideBySide && reportById.isEmpty)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 12,
                              child: _noReportHint(),
                            ),
                          // With the panel open the Event button anchors to
                          // the calendar pane instead of hovering over the
                          // panel.
                          if (panelVisible &&
                              _panelMode == CalendarPanelMode.tasks)
                            Positioned(
                              right: 16,
                              bottom: 16,
                              child: addEventFab,
                            ),
                        ],
                      );
                    },
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
    Map<String, Color>? colorById,
    ColorPrefs colorPrefs = const ColorPrefs(),
    Set<String>? remoteEditableFeedIds,
    Map<String, Node>? nodeById,
    Map<String, Node>? nodeByEventId,
    Set<String>? trackingNodeIds,
    Set<String>? trackingEventIds,
    Map<String, String>? assigneeLabelById,
    Set<String>? reportedEventIds,
    bool showCopyToReport = false,
    required List<DateTime> dayColumns,
    required double cellWidth,
    required double pixelsPerMinute,
    required bool isRtl,
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
    _gridTracker.rememberPosition(context, timeGrid: !event.allDay);
    final report = reportById[event.id];
    final isDraft = event.id == calendarDraftEventId;
    final baseColor =
        colorById?[event.id] ?? _eventColor(event, feedColors, colorPrefs);
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
    // Resize-handle drags convert px → minutes with this span, so it must
    // match what the tile actually renders: zero-duration events now show
    // at the visible floor instead of the old 60-minute fallback, which
    // made their handles move four times too fast.
    final durationMinutes = tileDuration(event).inSeconds / 60.0;
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
                // One-tap copy in the Plan + Report view, pinned
                // bottom-right so it never covers the title the play badge
                // already shares the top corner with. For when the day went
                // as scheduled but nothing was recorded: copies the planned
                // interval into the report lane as an accepted entry. Needs
                // a taller tile than the play badge (48px) so it clears the
                // title row; shorter tiles copy from the event detail's
                // time section instead.
                if (showCopyToReport &&
                    !isDraft &&
                    !event.allDay &&
                    !isReportDisplayId(event.id) &&
                    !isNodeBlockId(event.id) &&
                    !compactHandles &&
                    _view != CalendarView.month &&
                    (realHeight.isInfinite || realHeight >= 48) &&
                    (maxWidth == null || maxWidth >= 48) &&
                    isCopyablePlanEvent(
                      event,
                      reportedEventIds: reportedEventIds ?? const {},
                    ))
                  Positioned(
                    bottom: 2,
                    right: 2,
                    child: PlanCopyBadge(
                      key: ValueKey('plan-copy:${event.id}'),
                      onTapDown: _suppressNextTap,
                      onTap: () => _copyPlanToReport(event),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
    if (!_canDragTile(event, remoteEditableFeedIds) ||
        event.allDay ||
        _view == CalendarView.month ||
        dayColumns.isEmpty) {
      return tile;
    }
    // Time-grid tiles drag with the pointer that is in use: mouse/stylus
    // immediately, touch after a long press. Without this a desktop drag on
    // a tile scrolls the grid instead of moving the block.
    return PlanTileDragArea(
      key: ValueKey('plan-drag:${event.id}'),
      onPointerSignal: _gridTracker.onPlanPointerSignal,
      onDragStart: (position) => _onPairedPlanDragStart(
        event,
        position,
        days: dayColumns,
        cellWidth: cellWidth,
        pixelsPerMinute: pixelsPerMinute,
        isRtl: isRtl,
      ),
      onDragUpdate: _onPairedPlanDragMove,
      onDragEnd: () => _onPairedPlanDragEnd(event),
      onDragCancel: _cancelPairedPlanDrag,
      child: tile,
    );
  }

  /// Whether a tile can be dropped somewhere else. Everything movable in
  /// the calendar can be dragged; report chips and read-only synced or
  /// repeating events keep their existing tap/edit flow.
  bool _canDragTile(PlannerEvent event, Set<String>? remoteEditableFeedIds) {
    if (isReportDisplayId(event.id)) return false;
    if (event.id == calendarDraftEventId) return true;
    if (isNodeBlockId(event.id)) return true;
    if (remoteEditableFeedIds != null) {
      return _isMovableFast(event, remoteEditableFeedIds);
    }
    return _isMovable(event);
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
    if (isNodeBlockId(event.id)) return true;
    if (!event.isFromFeed) return event.recurrenceRule.isEmpty;
    if (!mounted) return false;
    return context.read<FeedCubit>().isRemoteEditable(event);
  }

  /// Set-based variant used by tiles: O(1) instead of an O(F) `byId` scan
  /// per tile per frame.
  bool _isMovableFast(PlannerEvent event, Set<String> remoteEditableFeedIds) {
    if (isReportDisplayId(event.id)) return false;
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
    final messenger = ScaffoldMessenger.of(context);
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
      showCalendarUndoSnackBar(
        messenger: messenger,
        message: _movedText(updated),
        onUndo: undoCubit.undo,
      );
      return;
    }
    final calendarCubit = context.read<CalendarCubit>();
    final nodesCubit = context.read<NodeCubit>();
    NodeEventSync.rescheduleLinkedEvent(calendarCubit, nodesCubit, updated);
    if (updated.reminderMinutesBefore == null) {
      unawaited(EventReminderService.cancelReminder(updated.id));
    } else {
      unawaited(EventReminderService.scheduleReminder(updated));
    }
    showCalendarUndoSnackBar(
      messenger: messenger,
      message: _movedText(updated),
      onUndo: undoCubit.undo,
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

  Color _eventColor(
    PlannerEvent event,
    Map<String, Color> feedColors, [
    ColorPrefs prefs = const ColorPrefs(),
  ]) => resolveEventColor(event, feedColors, prefs);

  /// Report block the panel should show: the selected chip, or — after a
  /// recording starts/stops and the chip's display id changes kind — the
  /// current block for the selected event.
  ReportBlock? _selectedReportBlock() {
    final reportId = _selectedReportId;
    if (reportId == null) return null;
    final direct = _projection.reportById[reportId];
    if (direct != null) return direct;
    final eventId = _selectedEventId;
    if (eventId == null) return null;
    for (final block in _projection.reportById.values) {
      if (block.eventId == eventId) return block;
    }
    return null;
  }

  Widget _buildSidePanel(int snap) {
    return CalendarSidePanel(
      mode: _panelMode,
      snapMinutes: snap,
      selectedEventId: _selectedEventId,
      selectedReport: _selectedReportBlock(),
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
      onRecordReport: _recordReport,
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

  void _openDetail(PlannerEvent event, {String? reportId}) {
    if (!_isWide) {
      if (_selectedEventId != null || _selectedReportId != reportId) {
        setState(() {
          _selectedEventId = null;
          _selectedReportId = reportId;
        });
      }
      final selectedReport = reportId == null
          ? null
          : _projection.reportById[reportId];
      showEventDetail(
        context,
        event: event,
        onReport: event.isTask ? () => _reportEvent(event) : null,
        report: selectedReport,
        onRecordReport: selectedReport == null
            ? null
            : () {
                _recordReport(selectedReport);
                Navigator.of(context).pop();
              },
      );
      return;
    }
    final wasCreating = _panelMode == CalendarPanelMode.creating;
    final captured = _preCreateSelectionCaptured;
    final preCreate = _preCreateSelectedDate;
    setState(() {
      _selectedEventId = event.id;
      _selectedReportId = reportId;
      _panelMode = CalendarPanelMode.detail;
      _panelOpen = true;
      _editPreview = null;
      _clearDraft();
      // Abandoning a draft for another event ends the create flow without
      // going through _finishCreating/_closeDrawer: undo the selection
      // takeover so no highlight lingers on the discarded draft's slot,
      // and drop the stash so a later close cannot restore a stale slot.
      if (wasCreating && captured) {
        _controller.selectedDate = preCreate;
      }
      if (wasCreating) {
        _preCreateSelectedDate = null;
        _preCreateSelectionCaptured = false;
      }
    });
  }

  /// Panel task tap: highlights the task's calendar entry, navigating the
  /// calendar to its day, without replacing the task list. The node menu
  /// stays one tap away in the tile's ⋮ menu. Falls back to the node's own
  /// schedule block; a task that isn't on the calendar yet jumps straight
  /// into a ghost block on its due date instead of asking how to schedule
  /// it.
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
    final blockStart = target == null && isSeedableBlock(schedule)
        ? schedule!.start
        : null;
    if (target == null && blockStart == null) {
      // Nothing on the calendar yet: jump straight into a ghost block on
      // the task's due date (noon by default, inside the visible hours)
      // instead of asking how to schedule it. The ⋮ menu keeps the full
      // schedule sheet for choosing day vs. time by hand.
      final snap = context.read<SettingsCubit>().state.snapMinutes;
      final seed = draftSeedFromNode(
        node,
        estimate: estimateForNode(context, node),
        snapMinutes: snap,
      );
      _seedFromPageMount = false;
      _openCreator(seed: seed);
      return;
    }
    final start = target?.start ?? blockStart!;
    setState(() {
      _selectedEventId = target?.id ?? nodeBlockId(node.id);
      _selectedReportId = null;
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
    if (mounted && _selectedReportId != displayId) {
      setState(() => _selectedReportId = displayId);
    }
    final calendar = context.read<CalendarCubit>();
    ReportedEntry? entry;
    try {
      entry = findReportEntryByDisplayId(
        context.read<ReportingCubit>().state,
        displayId,
      );
    } catch (_) {}
    final eventId =
        entry?.eventId ?? reportOwnerIdForDisplayId(displayId);
    if (eventId != null) {
      final event = calendar.byId(eventId);
      if (event != null) {
        _openDetail(event, reportId: displayId);
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
      return;
    }
    // A live block for a node-only recording has no event to open; its
    // owner is the node, so route the tap to the goal editor.
    final ownerId = reportOwnerIdForDisplayId(displayId);
    if (ownerId == null) return;
    Node? node;
    try {
      node = context.read<NodeCubit>().byId(ownerId);
    } catch (_) {}
    if (node != null) showNodeEditor(context, existing: node);
  }

  /// Commits a report chip resize. Manual entries, timer-logged events, and
  /// node-only reports each write back to their own store, so the drag
  /// feels like moving the report itself rather than editing the plan.
  void _adjustReportedInterval(
    ReportBlock block,
    DateTime start,
    DateTime end,
  ) {
    var adjusted = false;
    try {
      adjusted = applyReportedInterval(
        reporting: context.read<ReportingCubit>(),
        calendar: context.read<CalendarCubit>(),
        nodes: context.read<NodeCubit>(),
        block: block,
        start: start,
        end: end,
      );
      if (adjusted) {
        final undo = context.read<UndoCubit>();
        final messenger = ScaffoldMessenger.of(context);
        showCalendarUndoSnackBar(
          messenger: messenger,
          message:
              'Reported time updated · '
              '${_calendarTimeFormat.format(start)} – '
              '${_calendarTimeFormat.format(end)}',
          onUndo: undo.undo,
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Couldn’t adjust that report — please try again.'),
            duration: Duration(seconds: 2),
          ),
        );
    }
  }

  /// Starts another recording for the task behind a report chip. Works from
  /// the chip's ▶ and from the selected-report card in the side panel; a
  /// completed task records extra time without being reopened.
  void _recordReport(ReportBlock block) {
    if (block.kind == ReportBlockKind.live || !block.recordable) return;
    final calendar = context.read<CalendarCubit>();
    final ownerId = block.eventId ?? reportOwnerIdForDisplayId(block.displayId);
    if (ownerId == null) return;
    final event = calendar.byId(ownerId);
    NodeCubit? nodes;
    try {
      nodes = context.read<NodeCubit>();
    } catch (_) {}
    String? nodeId = event == null ? ownerId : null;
    if (event == null &&
        (nodeId == null || nodes == null || nodes.byId(nodeId) == null)) {
      return;
    }

    var started = false;
    if (nodes != null && event != null) {
      NodeEventLink.startEventTracking(
        nodes,
        calendar,
        event.id,
        allowCompleted: true,
      );
      final backing = event.isTask
          ? NodeEventLink.backingNodeFor(nodes, calendar, event.id)
          : null;
      nodeId = backing?.id;
      started =
          (calendar.byId(event.id)?.isTracking ?? false) ||
          (backing?.isTracking ?? false);
    } else if (nodes != null) {
      NodeEventLink.startNodeTracking(
        nodes,
        calendar,
        nodeId!,
        allowCompleted: true,
      );
      started = nodes.byId(nodeId)?.isTracking ?? false;
    } else {
      calendar.startTracking(ownerId);
      started = calendar.byId(ownerId)?.isTracking ?? false;
    }
    if (!started || !mounted) return;

    // Keep the panel's report card live when it was showing this report.
    if (event != null && _selectedEventId == event.id) {
      // Event-backed blocks keep their event id in the live display id even
      // when the timer runs on the backing node.
      final liveId = '$reportLiveDisplayIdPrefix${event.id}';
      if (_selectedReportId != liveId) {
        setState(() => _selectedReportId = liveId);
      }
    }
    final title = block.title.trim().isEmpty
        ? event?.subject.trim() ?? ''
        : block.title.trim();
    final messenger = ScaffoldMessenger.of(context);
    final undo = context.read<UndoCubit>();
    showCalendarUndoSnackBar(
      messenger: messenger,
      message: title.isEmpty
          ? 'Recording another report…'
          : 'Recording another report · $title',
      onUndo: undo.undo,
    );
  }

  /// Copies a plan tile's scheduled interval into the report lane as an
  /// accepted entry. For when the day went as scheduled but nothing was
  /// recorded: one tap, no timer, no editor. The lane chip can be dragged
  /// to adjust afterwards. Guards (via [copyPlanEventToReport]) keep
  /// double-taps and already-reported events from duplicating.
  void _copyPlanToReport(PlannerEvent event) {
    if (!mounted) return;
    copyPlanEventToReport(
      context,
      event,
      reportedEventIds: _projection.reportedEventIds,
    );
  }

  /// Drops one recorded run (or manual entry) from the Plan + Report
  /// column. The chip is the only place a single run can be deleted, so the
  /// task's other recordings stay intact.
  void _deleteReportedBlock(ReportBlock block) {
    var deleted = false;
    try {
      deleted = deleteReportedBlock(
        reporting: context.read<ReportingCubit>(),
        calendar: context.read<CalendarCubit>(),
        nodes: context.read<NodeCubit>(),
        block: block,
      );
      if (deleted) {
        final undo = context.read<UndoCubit>();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Deleted ${block.title.isEmpty ? 'report' : block.title} · '
              '${_calendarTimeFormat.format(block.start)} – '
              '${_calendarTimeFormat.format(block.end)}',
            ),
            action: SnackBarAction(label: 'Undo', onPressed: undo.undo),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Couldn’t delete that report — please try again.'),
        ),
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

  /// Mutates the create-flow fields without a `setState`, so [initState] can
  /// claim a pending seed before the first build (a setState there would be
  /// redundant) while [_openCreator] can wrap it for the live-seed path.
  void _applyCreatorState(PlannerEvent draft, {PlannerEvent? seed}) {
    // Remember the slot the user had selected before this create flow
    // took over the calendar selection, so a cancel can put it back.
    if (!_preCreateSelectionCaptured &&
        _panelMode != CalendarPanelMode.creating) {
      _preCreateSelectedDate = _controller.selectedDate;
      _preCreateSelectionCaptured = true;
    }
    _focusOnDraft(draft.start);
    _selectedEventId = null;
    _selectedReportId = null;
    _panelMode = CalendarPanelMode.creating;
    _panelOpen = true;
    _draftEvent = draft;
    _draftSeedSubject = seed?.subject;
    _draftSeedNotes = seed?.notes;
    _draftSeedLocation = seed?.location;
    _draftSeedClassLabel = seed?.classLabel;
    _draftSeedTaskId = seed?.taskId;
  }

  void _openCreator({
    DateTime? initialDate,
    TimeOfDay? initialTime,
    PlannerEvent? seed,
  }) {
    final draft = seed != null
        ? _asDraft(seed)
        : _initialDraft(initialDate: initialDate, initialTime: initialTime);
    if (!_isWide) {
      _applyCreatorState(draft, seed: seed);
      _openSheetCreator(draft);
      return;
    }
    setState(() => _applyCreatorState(draft, seed: seed));
  }

  Future<void> _openSheetCreator(PlannerEvent draft) async {
    setState(() {
      _selectedEventId = null;
      _selectedReportId = null;
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
    final wasCreating = _panelMode == CalendarPanelMode.creating;
    final captured = _preCreateSelectionCaptured;
    final preCreate = _preCreateSelectedDate;
    setState(() {
      _panelOpen = false;
      _panelMode = CalendarPanelMode.tasks;
      _selectedEventId = null;
      _selectedReportId = null;
      _editPreview = null;
      _seedFromPageMount = false;
      _clearDraft();
      if (wasCreating && captured) {
        _controller.selectedDate = preCreate;
      }
    });
    if (wasCreating) {
      _preCreateSelectedDate = null;
      _preCreateSelectionCaptured = false;
    }
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
          _selectedReportId = null;
          _editPreview = null;
          _clearDraft();
        });
    }
  }

  /// Finishes the edit form: back to the event's detail when it still
  /// exists; when it was just deleted, back to the task list — deleting an
  /// event must not close the panel. (Narrow screens keep their sheet
  /// behaviour: the editor sheet dismisses itself.)
  void _finishEditing() {
    final id = _selectedEventId;
    final stillThere = id == null
        ? null
        : context.read<CalendarCubit>().byId(id);
    if (stillThere == null) {
      setState(() {
        _panelMode = CalendarPanelMode.tasks;
        _selectedEventId = null;
        _selectedReportId = null;
        _editPreview = null;
        _clearDraft();
      });
      return;
    }
    setState(() {
      _panelMode = CalendarPanelMode.detail;
      _editPreview = null;
    });
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
    // On cancel (not saved), drop the create flow's takeover of the
    // calendar selection so no teal highlight lingers on the draft slot.
    final captured = _preCreateSelectionCaptured;
    final preCreate = _preCreateSelectedDate;
    if (!mounted) return;
    setState(() {
      _panelMode = CalendarPanelMode.tasks;
      _selectedEventId = null;
      _selectedReportId = null;
      _editPreview = null;
      _clearDraft();
      if (!saved && captured) {
        _controller.selectedDate = preCreate;
      }
    });
    _preCreateSelectedDate = null;
    _preCreateSelectionCaptured = false;
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

  void _onPairedPlanDragStart(
    PlannerEvent event,
    Offset globalPosition, {
    required List<DateTime> days,
    required double cellWidth,
    required double pixelsPerMinute,
    required bool isRtl,
  }) {
    _pairedDragOriginal = event;
    _pairedDragOrigin = globalPosition;
    _pairedDragPointer = globalPosition;
    _pairedDragDropTime = event.start;
    _pairedDragDay = localDay(event.start);
    _pairedDragDays = days;
    _pairedDragCellWidth = cellWidth;
    _pairedDragPixelsPerMinute = pixelsPerMinute;
    _pairedDragIsRtl = isRtl;
    _pairedDragScrollAtStart = _gridTracker.scrollOffset;
    final settings = context.read<SettingsCubit>().state;
    _pairedDragStartMinutes = settings.dayStartHour * 60;
    _pairedDragEndMinutes = settings.dayEndHour * 60;
    final duration = event.end.isAfter(event.start)
        ? event.end.difference(event.start).inMinutes
        : 60;
    _pairedDragDurationMinutes = duration.toDouble();
    _isDragging = true;
    _suppressTap = true;
    // While the pointer is parked over the time ruler (or the top/bottom
    // edge) keep scrolling the grid even though no pointer movement arrives.
    _pairedDragAutoScroll?.cancel();
    _pairedDragAutoScroll = Timer.periodic(
      const Duration(milliseconds: 16),
      _tickPairedPlanAutoScroll,
    );
  }

  void _onPairedPlanDragMove(Offset globalPosition) {
    _pairedDragPointer = globalPosition;
    _updatePairedPlanDropTime();
  }

  /// Converts the pointer into a drop time from the *grid* geometry, not the
  /// pointer delta alone: while the grid auto-scrolls under the pointer the
  /// time under the tile changes even when the pointer stands still.
  void _updatePairedPlanDropTime() {
    final original = _pairedDragOriginal;
    final origin = _pairedDragOrigin;
    final pointer = _pairedDragPointer;
    if (original == null || origin == null || pointer == null) return;
    final pixelsPerMinute = _pairedDragPixelsPerMinute;
    final cellWidth = _pairedDragCellWidth;
    if (pixelsPerMinute <= 0 || cellWidth <= 0 || _pairedDragDays.isEmpty) {
      return;
    }
    final scrollDelta = _gridTracker.scrollOffset - _pairedDragScrollAtStart;
    final movedMinutes =
        (pointer.dy - origin.dy + scrollDelta) / pixelsPerMinute;
    final startMinutes =
        original.start.hour * 60.0 +
        original.start.minute +
        movedMinutes.toDouble();
    final latestStart = _pairedDragEndMinutes - _pairedDragDurationMinutes;
    final targetMinutes = startMinutes.clamp(
      _pairedDragStartMinutes,
      latestStart < _pairedDragStartMinutes
          ? _pairedDragStartMinutes
          : latestStart,
    );
    final pointerDay = _dayUnderPointer(pointer, origin);
    if (pointerDay != null) _pairedDragDay = pointerDay;
    final day = _pairedDragDay ?? localDay(original.start);
    _pairedDragDropTime = DateTime(
      day.year,
      day.month,
      day.day,
    ).add(Duration(minutes: targetMinutes.round()));
  }

  /// Day column the pointer is over, or null when it is over the time
  /// ruler (the vertical auto-scroll handle). Null keeps the caller's last
  /// in-grid day instead of snapping to the first or last column.
  DateTime? _dayUnderPointer(Offset pointer, Offset origin) {
    final stack = _calendarStackKey.currentContext?.findRenderObject();
    final Rect? bounds = stack is RenderBox && stack.hasSize
        ? stack.localToGlobal(Offset.zero) & stack.size
        : null;
    final left = bounds?.left ?? origin.dx;
    final right = bounds?.right ?? origin.dx;
    final ruler = _calendarTimeRulerWidth;
    final gridLeft = _pairedDragIsRtl ? left : left + ruler;
    final gridRight = _pairedDragIsRtl ? right - ruler : right;
    if (gridRight - gridLeft <= 0) return null;
    final x = pointer.dx;
    if (_pairedDragIsRtl ? x >= gridRight : x <= gridLeft) return null;
    final column =
        ((_pairedDragIsRtl ? gridRight - x : x - gridLeft) / _pairedDragCellWidth)
            .floor()
            .clamp(0, _pairedDragDays.length - 1);
    final index = _pairedDragIsRtl
        ? _pairedDragDays.length - 1 - column
        : column;
    return _pairedDragDays[index];
  }

  void _tickPairedPlanAutoScroll(Timer timer) {
    final plan = _gridTracker.position;
    final pointer = _pairedDragPointer;
    final viewport = _gridTracker.viewportGlobal;
    if (plan == null || !plan.hasPixels || pointer == null || viewport == null) {
      return;
    }
    final velocity = _pairedPlanAutoScrollVelocity(pointer, viewport);
    if (velocity == 0) return;
    final target = (plan.pixels + velocity).clamp(
      plan.minScrollExtent,
      plan.maxScrollExtent,
    );
    if ((target - plan.pixels).abs() < 0.5) return;
    plan.jumpTo(target);
    _updatePairedPlanDropTime();
  }

  /// Pixels per tick to scroll while dragging. Over the time ruler the
  /// pointer's distance from the viewport's middle picks the direction and
  /// speed; near the top/bottom edge the usual edge auto-scroll applies.
  double _pairedPlanAutoScrollVelocity(Offset pointer, Rect viewport) {
    final stack = _calendarStackKey.currentContext?.findRenderObject();
    if (stack is! RenderBox || !stack.hasSize) return 0;
    final bounds = stack.localToGlobal(Offset.zero) & stack.size;
    if (pointer.dx < bounds.left || pointer.dx > bounds.right) return 0;
    final rulerEdge = _pairedDragIsRtl
        ? bounds.right - _calendarTimeRulerWidth
        : bounds.left + _calendarTimeRulerWidth;
    final overRuler = _pairedDragIsRtl
        ? pointer.dx >= rulerEdge
        : pointer.dx <= rulerEdge;
    if (overRuler) {
      final mid = viewport.center.dy;
      final deadZone = viewport.height * 0.2;
      final dy = pointer.dy - mid;
      if (dy.abs() <= deadZone) return 0;
      final travel = (viewport.height / 2 - deadZone).clamp(1.0, 1.0e6);
      final depth = ((dy.abs() - deadZone) / travel).clamp(0.0, 1.0);
      return dy.sign * (1.5 + depth * 6.5);
    }
    const edge = 28.0;
    if (pointer.dy < viewport.top + edge) {
      final depth = ((viewport.top + edge - pointer.dy) / edge).clamp(
        0.0,
        1.0,
      );
      return -(1.5 + depth * 6.5);
    }
    if (pointer.dy > viewport.bottom - edge) {
      final depth = ((pointer.dy - (viewport.bottom - edge)) / edge).clamp(
        0.0,
        1.0,
      );
      return 1.5 + depth * 6.5;
    }
    return 0;
  }

  Future<void> _onPairedPlanDragEnd(PlannerEvent event) async {
    final original = _pairedDragOriginal ?? event;
    final droppingTime = _pairedDragDropTime;
    if (droppingTime != null) _revealDropTime(droppingTime);
    _clearPairedPlanDrag();
    if (droppingTime == null || droppingTime == original.start) {
      _isDragging = false;
      if (mounted) setState(() {});
      _resetSuppressSoon();
      return;
    }
    await _onDragEnd(
      AppointmentDragEndDetails(original, null, null, droppingTime),
    );
  }

  /// Scrolls the grid when a fast drag drops the tile outside the visible
  /// hours, so the block cannot end up hidden above/below the viewport.
  void _revealDropTime(DateTime drop) {
    final position = _gridTracker.position;
    final viewport = _gridTracker.viewportGlobal;
    final pixelsPerMinute = _pairedDragPixelsPerMinute;
    if (position == null ||
        !position.hasPixels ||
        viewport == null ||
        pixelsPerMinute <= 0) {
      return;
    }
    final topInContent =
        (drop.hour * 60 + drop.minute - _pairedDragStartMinutes) *
        pixelsPerMinute;
    final visibleTop = position.pixels;
    final visibleBottom = visibleTop + viewport.height;
    if (topInContent >= visibleTop + 8 &&
        topInContent <= visibleBottom - 48) {
      return;
    }
    final target = (topInContent - viewport.height * 0.25).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    position.jumpTo(target);
  }

  void _cancelPairedPlanDrag() {
    if (_pairedDragOriginal == null) return;
    _clearPairedPlanDrag();
    _isDragging = false;
    if (mounted) setState(() {});
    _resetSuppressSoon();
  }

  void _clearPairedPlanDrag() {
    _pairedDragAutoScroll?.cancel();
    _pairedDragAutoScroll = null;
    _pairedDragOriginal = null;
    _pairedDragOrigin = null;
    _pairedDragPointer = null;
    _pairedDragDropTime = null;
    _pairedDragDay = null;
    _pairedDragDays = const [];
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
      if (appointment is PlannerEvent && isReportDisplayId(appointment.id)) {
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
      final dayStart = localDay(tappedDate);
      final dayEnd = shiftLocalDay(dayStart, 1);
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
