import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

import '../../common/undo/undo_bar.dart';
import '../../common/undo/undo_cubit.dart';
import '../../navigation/view/navigation_bar.dart';
import '../bloc/calendar_cubit.dart';
import '../bloc/calendar_draft_cubit.dart';
import '../bloc/feed_cubit.dart';
import '../bloc/task_cubit.dart';
import '../model/event_reschedule.dart';
import '../model/feed.dart';
import '../model/planner_event.dart';
import '../bloc/settings_cubit.dart';
import '../service/task_event_link.dart';
import 'event_editor.dart';
import 'feed_manager.dart';

const int _personalEventColor = 0xFF6B8F8A;
const double _wideBreakpoint = 720;
const double _drawerWidth = 360;

enum _DrawerMode { closed, detail, creating, editing }

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  final CalendarController _controller = CalendarController();
  CalendarView _view = CalendarView.week;
  String? _selectedEventId;
  _DrawerMode _drawerMode = _DrawerMode.closed;
  PlannerEvent? _draftEvent;
  String? _draftSeedSubject;
  String? _draftSeedNotes;
  String? _draftSeedLocation;
  String? _draftSeedClassLabel;
  String? _draftSeedTaskId;
  bool _suppressTap = false;
  PlannerEvent? _resizePreview;
  PlannerEvent? _handleOriginal;
  bool _handleTop = true;
  double _handleDy = 0;
  double _handlePxPerMinute = 1;
  bool _ignoreNativeDragEnd = false;

  bool get _isWide =>
      MediaQuery.of(context).size.width >= _wideBreakpoint;

  @override
  void initState() {
    super.initState();
    _view = context.read<SettingsCubit>().state.defaultCalendarView;
    _controller.view = _view;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final pending = context.read<CalendarDraftCubit>().takePending();
      if (pending != null) _openCreator(seed: pending);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feedCubit = context.watch<FeedCubit>();
    final feedColors = <String, Color>{
      for (final feed in feedCubit.state) feed.id: feed.color,
    };
    final snap = context.watch<SettingsCubit>().state.snapMinutes;
    final drawerOpen = _isWide && _drawerMode != _DrawerMode.closed;
    return BlocListener<CalendarDraftCubit, PlannerEvent?>(
      listener: (context, pending) {
        if (pending != null) {
          context.read<CalendarDraftCubit>().clear();
          _openCreator(seed: pending);
        }
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        actions: [
          IconButton(
            tooltip: 'Manage classes',
            icon: const Icon(Icons.sync),
            onPressed: () => showFeedManager(context),
          ),
          const UndoRedoActions(),
        ],
      ),
      bottomNavigationBar: const NavBar(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _onAddPressed,
        icon: const Icon(Icons.add),
        label: const Text('Event'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: SegmentedButton<CalendarView>(
              segments: const [
                ButtonSegment(
                  value: CalendarView.day,
                  icon: Icon(Icons.view_day),
                  label: Text('Day'),
                ),
                ButtonSegment(
                  value: CalendarView.week,
                  icon: Icon(Icons.view_column),
                  label: Text('Week'),
                ),
                ButtonSegment(
                  value: CalendarView.month,
                  icon: Icon(Icons.calendar_view_month),
                  label: Text('Month'),
                ),
              ],
              selected: {_view},
              onSelectionChanged: (selection) {
                setState(() => _view = selection.first);
                _controller.view = _view;
              },
            ),
          ),
          Expanded(
            child: BlocBuilder<CalendarCubit, List<PlannerEvent>>(
              builder: (context, events) {
                final visible =
                    context.watch<FeedCubit>().visibleEvents(events);
                final preview = _resizePreview;
                var shown = visible;
                final draft = _draftEvent;
                if (draft != null &&
                    _drawerMode == _DrawerMode.creating) {
                  shown = [...shown, draft];
                }
                if (preview != null) {
                  shown = [
                    for (final e in shown)
                      if (e.id == preview.id) preview else e,
                  ];
                }
                final calendar = SfCalendar(
                  controller: _controller,
                  view: _view,
                  dataSource: PlannerCalendarDataSource(
                    shown,
                    feedColors,
                  ),
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
                      _appointmentBuilder(feedColors, context, details),
                  onDragStart: _onDragStart,
                  onDragEnd: _onDragEnd,
                  onTap: _onTap,
                  monthViewSettings: const MonthViewSettings(
                    showAgenda: true,
                    appointmentDisplayMode:
                        MonthAppointmentDisplayMode.appointment,
                    agendaItemHeight: 44,
                  ),
                  timeSlotViewSettings: const TimeSlotViewSettings(
                    timeInterval: Duration(minutes: 30),
                    startHour: 6,
                    endHour: 24,
                  ),
                  todayHighlightColor: Theme.of(context).colorScheme.primary,
                );
                if (!drawerOpen) return calendar;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: calendar),
                    _buildDrawer(snap),
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
    CalendarAppointmentDetails details,
  ) {
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
    final raw =
        details.appointments.isNotEmpty ? details.appointments.first : null;
    final event = raw is PlannerEvent ? raw : null;
    if (event == null) return const SizedBox.shrink();
    final isDraft = event.id == calendarDraftEventId;
    final baseColor = _eventColor(event, feedColors);
    var color = isDraft ? baseColor.withValues(alpha: 0.55) : baseColor;
    if (event.isTask && event.done) {
      color = color.withValues(alpha: 0.55);
    }
    final selected = event.id == _selectedEventId;
    final movable = isDraft || (selected && _isMovable(event));
    final displaySubject =
        isDraft && event.subject.trim().isEmpty ? 'New event' : event.subject;
    final timeFormat = DateFormat('h:mm a');
    final timeLabel = event.allDay
        ? 'All day'
        : '${timeFormat.format(event.start)} – ${timeFormat.format(event.end)}';
    final durationMinutes = event.end.isAfter(event.start)
        ? event.end.difference(event.start).inSeconds / 60.0
        : 60.0;
    return Opacity(
      opacity: isDraft ? 0.85 : 1,
      child: Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
        border: (selected || isDraft)
            ? Border.all(color: Colors.white, width: 2)
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
          final twoLines =
              realHeight.isInfinite || realHeight >= 58;
          final showHandles = movable &&
              !event.allDay &&
              (realHeight.isInfinite || realHeight >= 58);
          final pxPerMinute = (realHeight.isFinite ? realHeight : details.bounds.height) /
              durationMinutes.clamp(1.0, 1440.0);
          final maxWidth =
              constraints.maxWidth.isFinite ? constraints.maxWidth : null;
          Widget body = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
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
                      child: Tooltip(
                        message: event.done
                            ? 'Mark not complete'
                            : 'Mark complete',
                        child: Checkbox(
                          value: event.done,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                          side: const BorderSide(
                            color: Colors.white,
                            width: 2,
                          ),
                          activeColor: Colors.white,
                          checkColor: baseColor,
                          onChanged: (_) =>
                              _toggleTaskDoneFromTag(event),
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
                        fontStyle:
                            isDraft ? FontStyle.italic : FontStyle.normal,
                        decoration: event.isTask && event.done
                            ? TextDecoration.lineThrough
                            : null,
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
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                  ),
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
            clipBehavior: Clip.none,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                child: showText ? body : const SizedBox.shrink(),
              ),
              if (showHandles)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _resizeHandle(
                    top: true,
                    event: event,
                    color: baseColor,
                    pxPerMinute: pxPerMinute,
                  ),
                ),
              if (showHandles)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: _resizeHandle(
                    top: false,
                    event: event,
                    color: baseColor,
                    pxPerMinute: pxPerMinute,
                  ),
                ),
            ],
          );
        },
      ),
      ),
    );
  }

  Widget _resizeHandle({
    required bool top,
    required PlannerEvent event,
    required Color color,
    required double pxPerMinute,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (_) =>
          _onHandleDragStart(event, top, pxPerMinute),
      onVerticalDragUpdate: _onHandleDragUpdate,
      onVerticalDragEnd: (_) => _onHandleDragEnd(),
      onVerticalDragCancel: _onHandleDragCancel,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpDown,
        child: Container(
          height: 28,
          alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
          padding: const EdgeInsets.only(top: 2, bottom: 2),
          child: Semantics(
            label: top ? 'Drag to change start time' : 'Drag to change end time',
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                  color: color.withValues(alpha: 0.9),
                  width: 3,
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
  void _toggleTaskDoneFromTag(PlannerEvent event) {
    _suppressTap = true;
    try {
      TaskEventLink.toggleEventDone(
        context.read<CalendarCubit>(),
        context.read<TaskCubit>(),
        event.id,
      );
    } catch (_) {}
    Future.delayed(const Duration(milliseconds: 300), () {
      _suppressTap = false;
    });
  }

  bool _isMovable(PlannerEvent event) {
    if (!event.isFromFeed) return event.recurrenceRule.isEmpty;
    if (!mounted) return false;
    return context.read<FeedCubit>().isRemoteEditable(event);
  }

  Future<void> _commitReschedule(
    PlannerEvent previous,
    PlannerEvent updated,
  ) async {
    if (updated.start == previous.start && updated.end == previous.end) {
      return;
    }
    final calendarCubit = context.read<CalendarCubit>();
    final messenger = ScaffoldMessenger.of(context);
    calendarCubit.updateEvent(updated);
    messenger.showSnackBar(
      SnackBar(
        content: Text(_movedText(updated)),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => context.read<UndoCubit>().undo(),
        ),
      ),
    );
    if (!previous.isFromFeed) return;
    // Optimistic: the new time is already applied above so the drop
    // feels instant. Push in the background; on failure revert.
    final error = await context.read<FeedCubit>().pushEventUpdate(updated);
    if (!mounted) return;
    if (error != null) {
      calendarCubit.updateEvent(previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    }
  }

  String _movedText(PlannerEvent event) {
    if (event.allDay) {
      return 'Moved to ${DateFormat('EEE, MMM d').format(event.start)}';
    }
    return 'Moved to ${DateFormat('EEE, MMM d · h:mm a').format(event.start)}';
  }

  String _blockedMessage(PlannerEvent event) {
    return 'Synced and repeating events can’t be moved by dragging — '
        'open the event to edit it instead.';
  }

  void _onHandleDragStart(
    PlannerEvent event,
    bool top,
    double pxPerMinute,
  ) {
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
      setState(() {});
      await _commitReschedule(original, preview);
    } else {
      setState(() {});
    }
    Future.delayed(const Duration(milliseconds: 300), () {
      _suppressTap = false;
    });
  }

  void _onHandleDragCancel() {
    _handleOriginal = null;
    _resizePreview = null;
    setState(() {});
    Future.delayed(const Duration(milliseconds: 300), () {
      _suppressTap = false;
    });
  }

  Color _eventColor(PlannerEvent event, Map<String, Color> feedColors) {
    final label = event.classLabel;
    if (label != null && label.isNotEmpty) return courseColor(label);
    final eventColor = event.colorValue;
    if (eventColor != null) return mutedCalendarColor(Color(eventColor));
    final feedColor = feedColors[event.feedId];
    if (feedColor != null) return mutedCalendarColor(feedColor);
    return const Color(_personalEventColor);
  }

  Widget _buildDrawer(int snap) {
    final theme = Theme.of(context);
    final String title;
    switch (_drawerMode) {
      case _DrawerMode.detail:
        title = 'Event details';
      case _DrawerMode.creating:
        title = 'New event';
      case _DrawerMode.editing:
        title = 'Edit event';
      case _DrawerMode.closed:
        title = '';
    }
    return Container(
      width: _drawerWidth,
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: theme.dividerColor)),
      ),
      child: Material(
        color: theme.colorScheme.surface,
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: 'Close panel',
                  icon: const Icon(Icons.close),
                  onPressed: _closeDrawer,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_drawerMode == _DrawerMode.detail)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Drag the event to move it · drag a circle to resize '
                '(snaps to $snap min) · hold at the edge to turn the page',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Expanded(
            child: BlocBuilder<CalendarCubit, List<PlannerEvent>>(
              builder: (context, events) {
                if (_drawerMode == _DrawerMode.creating) {
                  final draft = _draftEvent;
                  if (draft == null) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Preparing new event…'),
                      ),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Text(
                          'Ghost preview on the calendar — drag it to move it, '
                          'drag a circle to resize (snaps to $snap min). '
                          'Nothing is saved until you press Add.',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ),
                      Expanded(
                        child: EventEditorForm(
                          key: const ValueKey('new:draft'),
                          initialDate: DateTime(
                            draft.start.year,
                            draft.start.month,
                            draft.start.day,
                          ),
                          initialTime: draft.allDay
                              ? null
                              : TimeOfDay.fromDateTime(draft.start),
                          initialEndTime: draft.allDay
                              ? null
                              : TimeOfDay.fromDateTime(draft.end),
                          initialSubject: _draftSeedSubject,
                          initialNotes: _draftSeedNotes,
                          initialLocation: _draftSeedLocation,
                          initialClassLabel: _draftSeedClassLabel,
                          initialTaskId: _draftSeedTaskId,
                          onDraftChanged: _onDraftChanged,
                          autofocusTitle: true,
                          onFinished: _closeDrawer,
                          onCancelled: _closeDrawer,
                        ),
                      ),
                    ],
                  );
                }
                final selectedId = _selectedEventId;
                PlannerEvent? event;
                if (selectedId != null) {
                  for (final e in events) {
                    if (e.id == selectedId) {
                      event = e;
                      break;
                    }
                  }
                }
                if (event == null) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('This event was deleted.'),
                    ),
                  );
                }
                if (_drawerMode == _DrawerMode.editing) {
                  return EventEditorForm(
                    key: ValueKey('edit:${event.id}'),
                    existing: event,
                    allowDelete: true,
                    onFinished: () {
                      final stillThere =
                          context.read<CalendarCubit>().byId(event!.id);
                      if (stillThere == null) {
                        _closeDrawer();
                      } else {
                        setState(() => _drawerMode = _DrawerMode.detail);
                      }
                    },
                    onCancelled: () =>
                        setState(() => _drawerMode = _DrawerMode.detail),
                  );
                }
                return SingleChildScrollView(
                  child: EventDetailView(
                    key: ValueKey('detail:${event.id}'),
                    event: event,
                    onEdit: () => setState(
                      () => _drawerMode = _DrawerMode.editing,
                    ),
                    onClose: _closeDrawer,
                  ),
                );
              },
            ),
          ),
        ],
        ),
      ),
    );
  }

  void _onAddPressed() {
    if (_drawerMode == _DrawerMode.creating && _draftEvent != null) return;
    final selected = _controller.selectedDate ?? DateTime.now();
    _openCreator(initialDate: selected);
  }

  void _openDetail(PlannerEvent event) {
    if (!_isWide) {
      if (_selectedEventId != null) {
        setState(() => _selectedEventId = null);
      }
      showEventDetail(context, event: event);
      return;
    }
    setState(() {
      _selectedEventId = event.id;
      _drawerMode = _DrawerMode.detail;
      _clearDraft();
    });
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
            day.year, day.month, day.day, initialTime.hour, initialTime.minute),
        snap,
      );
    } else {
      start = DateTime(day.year, day.month, day.day, 9);
    }
    var end = initialEndTime == null
        ? start.add(const Duration(hours: 1))
        : snapToInterval(
            DateTime(day.year, day.month, day.day, initialEndTime.hour,
                initialEndTime.minute),
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
        : _initialDraft(
            initialDate: initialDate,
            initialTime: initialTime,
          );
    _focusOnDraft(draft.start);
    if (!_isWide) {
      _openSheetCreator(draft);
      return;
    }
    setState(() {
      _selectedEventId = null;
      _drawerMode = _DrawerMode.creating;
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
      _drawerMode = _DrawerMode.creating;
      _draftEvent = draft;
      _draftSeedSubject = draft.subject.isEmpty ? null : draft.subject;
      _draftSeedNotes = draft.notes;
      _draftSeedLocation = draft.location;
      _draftSeedClassLabel = draft.classLabel;
      _draftSeedTaskId = draft.taskId;
    });
    await showEventEditor(
      context,
      initialDate:
          DateTime(draft.start.year, draft.start.month, draft.start.day),
      initialTime:
          draft.allDay ? null : TimeOfDay.fromDateTime(draft.start),
      initialEndTime:
          draft.allDay ? null : TimeOfDay.fromDateTime(draft.end),
      initialSubject: _draftSeedSubject,
      initialNotes: _draftSeedNotes,
      initialLocation: _draftSeedLocation,
      initialClassLabel: _draftSeedClassLabel,
      initialTaskId: _draftSeedTaskId,
      onDraftChanged: _onDraftChanged,
    );
    if (!mounted) return;
    setState(() {
      _drawerMode = _DrawerMode.closed;
      _clearDraft();
    });
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
      _drawerMode = _DrawerMode.closed;
      _selectedEventId = null;
      _clearDraft();
    });
  }

  void _onTap(CalendarTapDetails details) {
    if (_suppressTap) return;
    if (details.targetElement == CalendarElement.appointment) {
      final raw = details.appointments?.isNotEmpty ?? false
          ? details.appointments!.first
          : null;
      if (raw is PlannerEvent && raw.id == calendarDraftEventId) return;
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
      if (_drawerMode == _DrawerMode.creating && _draftEvent != null) {
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
    _suppressTap = true;
    if (_handleOriginal != null) {
      _ignoreNativeDragEnd = true;
    }
  }

  Future<void> _onDragEnd(AppointmentDragEndDetails details) async {
    if (_ignoreNativeDragEnd) {
      _ignoreNativeDragEnd = false;
      setState(() {});
      Future.delayed(const Duration(milliseconds: 300), () {
        _suppressTap = false;
      });
      return;
    }
    Future.delayed(const Duration(milliseconds: 300), () {
      _suppressTap = false;
    });
    // Every path below ends in a rebuild so the calendar always renders
    // from real data — a dropped block can never be left floating.
    try {
      final appointment = details.appointment;
      final droppingTime = details.droppingTime;
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
      final event = context.read<CalendarCubit>().byId(appointment.id) ??
          appointment;
      if (!_isMovable(event)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_blockedMessage(event))),
          );
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
      final dayStart = DateTime(
        tappedDate.year,
        tappedDate.month,
        tappedDate.day,
      );
      final dayEnd = dayStart.add(const Duration(days: 1));
      final candidates = <PlannerEvent>[];
      for (final event in cubit.state) {
        if (!feedCubit.isFeedVisible(event.feedId)) continue;
        if (event.recurrenceRule.isEmpty) continue;
        final occurrences = cubit.occurrencesOf(event, dayStart, dayEnd);
        if (occurrences.isEmpty) continue;
        final exact = occurrences.any(
          (o) =>
              o.hour == tappedDate.hour && o.minute == tappedDate.minute,
        );
        if (exact) return event;
        candidates.add(event);
      }
      if (candidates.length == 1) return candidates.first;
    }
    return null;
  }
}

class PlannerCalendarDataSource extends CalendarDataSource {
  final List<PlannerEvent> _events;
  final Map<String, Color> feedColors;

  PlannerCalendarDataSource(this._events, this.feedColors) {
    appointments = _events;
  }

  /// Maps a dragged occurrence back onto our event model. Syncfusion calls
  /// this when a drag starts and ends; without it the drag callbacks
  /// receive null and drops silently do nothing.
  @override
  dynamic convertAppointmentToObject(
    dynamic customData,
    Appointment appointment,
  ) {
    if (customData is! PlannerEvent) return customData;
    return customData.copyWith(
      start: appointment.startTime,
      end: appointment.endTime,
      allDay: appointment.isAllDay,
    );
  }

  @override
  DateTime getStartTime(int index) => _events[index].start;

  @override
  DateTime getEndTime(int index) {
    final event = _events[index];
    if (event.allDay && !event.end.isAfter(event.start)) {
      return event.start.add(const Duration(days: 1));
    }
    return event.end;
  }

  @override
  bool isAllDay(int index) => _events[index].allDay;

  @override
  String getSubject(int index) => _events[index].subject;

  @override
  String? getNotes(int index) => _events[index].notes;

  @override
  String? getLocation(int index) => _events[index].location;

  @override
  String getRecurrenceRule(int index) => _events[index].recurrenceRule;

  @override
  Object? getId(int index) => _events[index].id;

  @override
  Color getColor(int index) {
    final event = _events[index];
    final label = event.classLabel;
    if (label != null && label.isNotEmpty) return courseColor(label);
    final eventColor = event.colorValue;
    if (eventColor != null) return mutedCalendarColor(Color(eventColor));
    final feedColor = feedColors[event.feedId];
    if (feedColor != null) return mutedCalendarColor(feedColor);
    return const Color(_personalEventColor);
  }
}
