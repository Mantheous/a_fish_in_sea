import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/calendar_cubit.dart';
import '../bloc/calendar_panel_cubit.dart';
import '../model/planner_event.dart';
import '../service/calendar_report.dart';
import 'event_editor.dart';

/// Key for the drag handle that resizes the panel.
const Key calendarPanelResizeHandleKey = Key('calendar-panel-resize-handle');

/// Grab strip at the panel's left edge. Pressing and dragging horizontally
/// resizes the panel; the strip stays translucent so the few pixels it
/// overlaps keep receiving taps.
const double _resizeHandleWidth = 8;

/// Minimum width the calendar keeps beside the panel when sizing.
const double _minCalendarWidth = 360;

/// What the side panel shows: the task list when nothing is selected, or
/// the selected event's detail / editor.
enum CalendarPanelMode { tasks, detail, creating, editing }

/// Right-hand side panel on wide screens, rendered by [CalendarPage].
/// Content lives here; mode transitions and draft/selection state stay in
/// the page.
class CalendarSidePanel extends StatelessWidget {
  const CalendarSidePanel({
    super.key,
    required this.mode,
    required this.snapMinutes,
    required this.selectedEventId,
    required this.selectedReport,
    required this.draft,
    required this.seedSubject,
    required this.seedNotes,
    required this.seedLocation,
    required this.seedClassLabel,
    required this.seedTaskId,
    required this.tasksContent,
    required this.onDraftChanged,
    required this.onEditChanged,
    required this.onCreatingFinished,
    required this.onEditingFinished,
    required this.onEditingCancelled,
    required this.onEditRequested,
    required this.onBack,
    required this.onClose,
    required this.onReport,
    required this.onRecordReport,
  });

  final CalendarPanelMode mode;
  final int snapMinutes;
  final String? selectedEventId;

  /// Report chip selected in the Plan + Report lane, if any. Its details
  /// lead the event detail.
  final ReportBlock? selectedReport;

  /// Preview event the create form is editing.
  final PlannerEvent? draft;

  // Seeds for the "new event from a task" flow, forwarded to the form.
  final String? seedSubject;
  final String? seedNotes;
  final String? seedLocation;
  final String? seedClassLabel;
  final String? seedTaskId;

  /// Panel body for [CalendarPanelMode.tasks]; built by the page so this
  /// widget stays free of task-list wiring.
  final Widget tasksContent;

  final ValueChanged<PlannerEvent> onDraftChanged;
  final ValueChanged<PlannerEvent> onEditChanged;
  final void Function(bool saved) onCreatingFinished;
  final VoidCallback onEditingFinished;
  final VoidCallback onEditingCancelled;
  final VoidCallback onEditRequested;

  /// Header back arrow: back to the task list (cancels a draft, leaves an
  /// edit form for the event's detail). Closing the panel stays on `onClose`.
  final VoidCallback onBack;
  final VoidCallback onClose;
  final ValueChanged<PlannerEvent> onReport;

  /// Panel twin of the report chips' play button: starts another recording
  /// for the selected report's task.
  final ValueChanged<ReportBlock> onRecordReport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = switch (mode) {
      CalendarPanelMode.detail => 'Event details',
      CalendarPanelMode.creating => 'New event',
      CalendarPanelMode.editing => 'Edit event',
      CalendarPanelMode.tasks => 'Tasks',
    };
    final width = _panelWidth(context);
    return SizedBox(
      width: width,
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: theme.dividerColor)),
              ),
              child: Material(
                color: theme.colorScheme.surface,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 12, 8, 8),
                      child: Row(
                        children: [
                          if (mode == CalendarPanelMode.tasks)
                            const SizedBox(width: 8)
                          else
                            IconButton(
                              tooltip: switch (mode) {
                                CalendarPanelMode.creating => 'Cancel new event',
                                CalendarPanelMode.editing => 'Back to details',
                                _ => 'Back to tasks',
                              },
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.arrow_back),
                              onPressed: onBack,
                            ),
                          Expanded(
                            child: Text(title, style: theme.textTheme.titleMedium),
                          ),
                          IconButton(
                            tooltip: 'Close panel',
                            icon: const Icon(Icons.close),
                            onPressed: onClose,
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    if (mode == CalendarPanelMode.detail)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Text(
                          'Drag the event to move it · drag a circle to resize '
                          '(snaps to $snapMinutes min) · hold at the edge to turn '
                          'the page',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    Expanded(
                      // Keep the task list alive while an event is open so its
                      // scroll position, expansion and selection survive the
                      // round trip back to Tasks.
                      child: IndexedStack(
                        index: mode == CalendarPanelMode.tasks ? 0 : 1,
                        sizing: StackFit.expand,
                        children: [
                          tasksContent,
                          _buildContent(context),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Left-edge grab strip: drag to resize, double-click to
          // reset. Translucent, so the pixels it overlaps keep
          // receiving taps.
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: _PanelResizeHandle(
              width: width,
              onResize: (delta) => _resizeBy(context, width, delta),
            ),
          ),
        ],
      ),
    );
  }

  /// Current panel width: the user's drag (via [CalendarPanelCubit])
  /// or the default, clamped so the calendar always keeps
  /// [_minCalendarWidth] beside the panel.
  double _panelWidth(BuildContext context) {
    var width = calendarPanelDefaultWidth;
    try {
      width = context.watch<CalendarPanelCubit>().state;
    } catch (_) {}
    final screen = MediaQuery.sizeOf(context).width;
    final maxWidth = math.max(
      calendarPanelMinWidth,
      math.min(calendarPanelMaxWidth, screen - _minCalendarWidth),
    );
    return width.clamp(calendarPanelMinWidth, maxWidth).toDouble();
  }

  /// Drags left to widen. Without a [CalendarPanelCubit] (standalone
  /// embeds) the handle stays inert at the default width.
  void _resizeBy(BuildContext context, double current, double delta) {
    try {
      context.read<CalendarPanelCubit>().setWidth(current - delta);
    } catch (_) {}
  }

  Widget _buildContent(BuildContext context) {
    return BlocBuilder<CalendarCubit, List<PlannerEvent>>(
      builder: (context, events) {
        if (mode == CalendarPanelMode.creating) {
          final draftEvent = draft;
          if (draftEvent == null) {
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
                  'drag a circle to resize (snaps to $snapMinutes min). '
                  'Page with the arrows and the ghost follows. '
                  'Nothing is saved until you press Add.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              Expanded(
                child: EventEditorForm(
                  key: const ValueKey('new:draft'),
                  initialDate: DateTime(
                    draftEvent.start.year,
                    draftEvent.start.month,
                    draftEvent.start.day,
                  ),
                  initialTime: draftEvent.allDay
                      ? null
                      : TimeOfDay.fromDateTime(draftEvent.start),
                  initialEndTime: draftEvent.allDay
                      ? null
                      : TimeOfDay.fromDateTime(draftEvent.end),
                  initialSubject: seedSubject,
                  initialNotes: seedNotes,
                  initialLocation: seedLocation,
                  initialClassLabel: seedClassLabel,
                  initialTaskId: seedTaskId,
                  onDraftChanged: onDraftChanged,
                  autofocusTitle: true,
                  onFinished: () => onCreatingFinished(true),
                  onCancelled: () => onCreatingFinished(false),
                ),
              ),
            ],
          );
        }
        final selectedId = selectedEventId;
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
        final detailEvent = event;
        if (mode == CalendarPanelMode.editing) {
          return EventEditorForm(
            key: ValueKey('edit:${detailEvent.id}'),
            existing: detailEvent,
            allowDelete: true,
            onDraftChanged: onEditChanged,
            onFinished: onEditingFinished,
            onCancelled: onEditingCancelled,
          );
        }
        final report = selectedReport;
        return SingleChildScrollView(
          child: EventDetailView(
            key: ValueKey('detail:${detailEvent.id}'),
            event: detailEvent,
            onEdit: onEditRequested,
            onReport: detailEvent.isTask ? () => onReport(detailEvent) : null,
            onClose: onClose,
            report: report,
            onRecordReport:
                report == null ? null : () => onRecordReport(report),
          ),
        );
      },
    );
  }
}


/// The grab strip on the panel's left edge: a resize cursor and a colored
/// line on hover, horizontal drags resize, double-click resets to the
/// default width.
class _PanelResizeHandle extends StatefulWidget {
  const _PanelResizeHandle({required this.width, required this.onResize});

  final double width;
  final ValueChanged<double> onResize;

  @override
  State<_PanelResizeHandle> createState() => _PanelResizeHandleState();
}

class _PanelResizeHandleState extends State<_PanelResizeHandle> {
  bool _hovered = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = _hovered || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        key: calendarPanelResizeHandleKey,
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (details) => widget.onResize(details.delta.dx),
        onHorizontalDragEnd: (_) => setState(() => _dragging = false),
        onHorizontalDragCancel: () => setState(() => _dragging = false),
        onDoubleTap: () {
          try {
            context.read<CalendarPanelCubit>().resetWidth();
          } catch (_) {}
        },
        child: Semantics(
          label: 'Resize panel',
          child: SizedBox(
            width: _resizeHandleWidth,
            height: double.infinity,
            child: Align(
              alignment: Alignment.centerLeft,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: active ? 3 : 1,
                height: double.infinity,
                color:
                    active ? theme.colorScheme.primary : Colors.transparent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
