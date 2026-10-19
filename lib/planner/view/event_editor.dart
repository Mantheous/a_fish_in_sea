import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../common/undo/undo_cubit.dart';
import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/model/node.dart';
import '../../nodes/service/node_event_link.dart';
import '../../nodes/service/node_event_sync.dart';
import '../../nodes/view/goal_picker.dart';
import '../../nodes/view/node_checkbox.dart';
import '../../reporting/bloc/places_cubit.dart';
import '../../reporting/model/place.dart';
import '../bloc/calendar_cubit.dart';
import '../bloc/calendar_draft_cubit.dart';
import '../bloc/feed_cubit.dart';
import '../bloc/settings_cubit.dart';
import '../model/event_reschedule.dart';
import '../model/feed.dart';
import '../model/planner_event.dart';
import '../model/recurrence.dart';
import '../model/task_assignee.dart';
import '../service/event_reminders.dart';
import 'event_editor_actions.dart';
import 'event_time_sections.dart';
import 'people_field.dart';
import 'reminder_prompt.dart' show ReminderField, maybePromptForEventReminder;

const int _personalEventColor = 0xFF6B8F8A;

Future<bool?> showEventEditor(
  BuildContext context, {
  PlannerEvent? existing,
  DateTime? initialDate,
  TimeOfDay? initialTime,
  TimeOfDay? initialEndTime,
  String? initialSubject,
  String? initialNotes,
  String? initialLocation,
  String? initialClassLabel,
  String? initialTaskId,
  ValueChanged<PlannerEvent>? onDraftChanged,
  bool allowDelete = true,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enableDrag: true,
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      minChildSize: 0.32,
      maxChildSize: 0.92,
      builder: (context, scrollController) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: _EventEditorSheet(
          existing: existing,
          initialDate: initialDate,
          initialTime: initialTime,
          initialEndTime: initialEndTime,
          initialSubject: initialSubject,
          initialNotes: initialNotes,
          initialLocation: initialLocation,
          initialClassLabel: initialClassLabel,
          initialTaskId: initialTaskId,
          onDraftChanged: onDraftChanged,
          allowDelete: allowDelete,
          scrollController: scrollController,
        ),
      ),
    ),
  );
}

Future<void> showEventDetail(
  BuildContext context, {
  required PlannerEvent event,
  VoidCallback? onReport,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) =>
        _EventDetailSheet(event: event, onReport: onReport),
  );
}

class _EventEditorSheet extends StatelessWidget {
  final PlannerEvent? existing;
  final DateTime? initialDate;
  final TimeOfDay? initialTime;
  final TimeOfDay? initialEndTime;
  final String? initialSubject;
  final String? initialNotes;
  final String? initialLocation;
  final String? initialClassLabel;
  final String? initialTaskId;
  final ValueChanged<PlannerEvent>? onDraftChanged;
  final bool allowDelete;
  final ScrollController? scrollController;

  const _EventEditorSheet({
    this.existing,
    this.initialDate,
    this.initialTime,
    this.initialEndTime,
    this.initialSubject,
    this.initialNotes,
    this.initialLocation,
    this.initialClassLabel,
    this.initialTaskId,
    this.onDraftChanged,
    this.allowDelete = true,
    this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Theme.of(context).dividerColor,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Flexible(
          child: EventEditorForm(
            existing: existing,
            initialDate: initialDate,
            initialTime: initialTime,
            initialEndTime: initialEndTime,
            initialSubject: initialSubject,
            initialNotes: initialNotes,
            initialLocation: initialLocation,
            initialClassLabel: initialClassLabel,
            initialTaskId: initialTaskId,
            onDraftChanged: onDraftChanged,
            allowDelete: allowDelete,
            scrollController: scrollController,
            autofocusTitle: existing == null,
            title: existing == null ? 'New event' : 'Edit event',
            onFinished: () => Navigator.of(context).pop(true),
            onCancelled: () => Navigator.of(context).pop(false),
          ),
        ),
      ],
    );
  }
}

class EventEditorForm extends StatefulWidget {
  final PlannerEvent? existing;
  final DateTime? initialDate;
  final TimeOfDay? initialTime;
  final TimeOfDay? initialEndTime;
  final String? initialSubject;
  final String? initialNotes;
  final String? initialLocation;
  final String? initialClassLabel;
  final String? initialTaskId;
  final ValueChanged<PlannerEvent>? onDraftChanged;
  final bool allowDelete;
  final bool autofocusTitle;
  final String? title;
  final VoidCallback? onFinished;
  final VoidCallback? onCancelled;
  final ScrollController? scrollController;

  const EventEditorForm({
    super.key,
    this.existing,
    this.initialDate,
    this.initialTime,
    this.initialEndTime,
    this.initialSubject,
    this.initialNotes,
    this.initialLocation,
    this.initialClassLabel,
    this.initialTaskId,
    this.onDraftChanged,
    this.allowDelete = true,
    this.autofocusTitle = false,
    this.title,
    this.onFinished,
    this.onCancelled,
    this.scrollController,
  });

  @override
  State<EventEditorForm> createState() => EventEditorFormState();
}

class EventEditorFormState extends State<EventEditorForm> {
  late final TextEditingController _subject;
  late final TextEditingController _notes;
  late final TextEditingController _location;
  late DateTime _date;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  late bool _allDay;
  late RepeatKind _repeatKind;
  late Set<int> _weekDays;
  late RepeatEndKind _endKind;
  late int _count;
  late DateTime? _until;
  bool _customRepeat = false;
  bool _saving = false;
  String? _saveTargetFeedId;
  String? _sourceTaskId;
  String? _placeId;
  late List<TaskAssignee> _people;
  late bool _isTask;
  late bool _done;
  int? _reminderMinutesBefore;
  PlannerEvent? _seriesMaster;
  bool _loadingMaster = false;
  bool _masterFailed = false;
  bool _repeatTouched = false;
  Timer? _draftDebounce;

  bool get _isSeriesInstance =>
      widget.existing?.isRecurringInstance ?? false;

  /// Whether the editor should offer a calendar picker for [existing].
  /// Personal events and single (non-recurring) Google events can move
  /// between "This device" and any writable Google calendar. Read-only
  /// feed events aren't editable at all, and repeating Google events are
  /// excluded: moving one occurrence vs. a whole series needs different
  /// Google calls and would risk duplicating the series.
  bool _canChangeCalendar(PlannerEvent existing, FeedCubit feeds) {
    if (!feeds.isEventEditable(existing)) return false;
    if (existing.isRecurringInstance) return false;
    if (existing.isFromFeed && existing.recurrenceRule.isNotEmpty) {
      return false;
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    _subject = TextEditingController();
    _notes = TextEditingController();
    _location = TextEditingController();
    _sourceTaskId = widget.existing?.taskId ?? widget.initialTaskId;
    final defaultFeedId =
        context.read<SettingsCubit>().state.defaultEventFeedId;
    if (widget.existing == null) {
      if (defaultFeedId != null && defaultFeedId.isNotEmpty) {
        final feed = context.read<FeedCubit>().byId(defaultFeedId);
        if (feed != null &&
            feed.kind == FeedKind.google &&
            feed.calendarId != null &&
            feed.calendarId!.isNotEmpty) {
          _saveTargetFeedId = defaultFeedId;
        }
      }
    } else {
      final existingFeedId = widget.existing!.feedId;
      if (existingFeedId != null && existingFeedId.isNotEmpty) {
        try {
          final feed = context.read<FeedCubit>().byId(existingFeedId);
          if (feed != null &&
              feed.kind == FeedKind.google &&
              feed.calendarId != null &&
              feed.calendarId!.isNotEmpty) {
            _saveTargetFeedId = existingFeedId;
          }
        } catch (_) {}
      }
    }
    _applyEvent(
      widget.existing,
      initialDate: widget.initialDate,
      initialTime: widget.initialTime,
      initialEndTime: widget.initialEndTime,
      initialSubject: widget.initialSubject,
      initialNotes: widget.initialNotes,
      initialLocation: widget.initialLocation,
    );
    if (widget.onDraftChanged != null) {
      // Debounced: every keystroke used to rebuild the whole CalendarPage
      // (SfCalendar + ghost) synchronously, which made typing laggy.
      // Also attached in edit mode so the tile preview tracks the title.
      _subject.addListener(_scheduleDraft);
      _notes.addListener(_scheduleDraft);
      _location.addListener(_scheduleDraft);
    }
    final existing = widget.existing;
    if (existing != null && existing.isRecurringInstance) {
      if (context.read<FeedCubit>().isRemoteEditable(existing)) {
        _loadingMaster = true;
        _loadMaster();
      } else {
        _customRepeat = true;
      }
    }
  }

  Future<void> _loadMaster() async {
    final existing = widget.existing;
    if (existing == null) return;
    final master =
        await context.read<FeedCubit>().fetchSeriesMaster(existing);
    if (!mounted) return;
    setState(() {
      _loadingMaster = false;
      if (master == null) {
        _masterFailed = true;
      } else {
        _seriesMaster = master;
        // Sync only the repeat UI from the master so an untouched save
        // preserves the series rule. Title/date stay on the occurrence:
        // a single-occurrence edit must not inherit the master's date,
        // and a series edit rebuilds the master's date separately.
        if (!_repeatTouched) {
          final config = RepeatConfig.tryParse(master.recurrenceRule);
          if (config == null && master.recurrenceRule.isNotEmpty) {
            _customRepeat = true;
          } else if (config != null) {
            _customRepeat = false;
            _repeatKind = config.kind;
            _weekDays = config.weekDays.toSet();
            _endKind = config.endKind;
            _count = config.count;
            _until = config.until;
          }
        }
      }
    });
  }

  void _applyEvent(
    PlannerEvent? existing, {
    DateTime? initialDate,
    TimeOfDay? initialTime,
    TimeOfDay? initialEndTime,
    String? initialSubject,
    String? initialNotes,
    String? initialLocation,
  }) {
    _subject.text = existing?.subject ?? initialSubject ?? '';
    _notes.text = existing?.notes ?? initialNotes ?? '';
    _location.text = existing?.location ?? initialLocation ?? '';
    _placeId = existing?.placeId;
    _people = List.of(existing?.assignees ?? const []);
    if (existing == null && _people.isEmpty && _sourceTaskId != null) {
      // Creating a calendar block for a node: start from the node's people
      // so saving back can't silently drop them.
      try {
        final node = context.read<NodeCubit>().byId(_sourceTaskId!);
        if (node != null && node.assignees.isNotEmpty) {
          _people = List.of(node.assignees);
        }
      } catch (_) {}
    }
    // Scheduling something out of the Tasks menu ("Add to calendar" on a
    // task) means the event *is* that task's plan, so the switch starts
    // on instead of silently demoting the assignment to a plain calendar
    // event. An existing event always keeps whatever flag it was saved
    // with — including a deliberate un-check.
    final seededFromTask = widget.existing == null && _sourceTaskId != null;
    _isTask = existing?.isTask ?? seededFromTask;
    _done = existing?.done ?? false;
    _reminderMinutesBefore = existing?.reminderMinutesBefore;
    if (existing != null) {
      _date = DateTime(
        existing.start.year,
        existing.start.month,
        existing.start.day,
      );
      _allDay = existing.allDay;
      _startTime = TimeOfDay.fromDateTime(existing.start);
      final endRef = existing.end.isAfter(existing.start)
          ? existing.end
          : existing.start.add(const Duration(hours: 1));
      _endTime = TimeOfDay.fromDateTime(endRef);
      final config = RepeatConfig.tryParse(existing.recurrenceRule);
      if (config == null && existing.recurrenceRule.isNotEmpty) {
        _customRepeat = true;
        _repeatKind = RepeatKind.none;
        _weekDays = const {};
        _endKind = RepeatEndKind.never;
        _count = 0;
        _until = null;
      } else {
        _customRepeat = false;
        _repeatKind = config?.kind ?? RepeatKind.none;
        _weekDays = config?.weekDays.toSet() ?? {existing.start.weekday};
        _endKind = config?.endKind ?? RepeatEndKind.never;
        _count = config?.count ?? 0;
        _until = config?.until;
      }
    } else {
      final initial = initialDate ?? DateTime.now();
      _date = DateTime(initial.year, initial.month, initial.day);
      _allDay = false;
      final tapped = initialTime;
      _startTime = tapped ?? const TimeOfDay(hour: 9, minute: 0);
      _endTime = initialEndTime ??
          TimeOfDay(
            hour: (_startTime.hour + 1) % 24,
            minute: _startTime.minute,
          );
      _repeatKind = RepeatKind.none;
      _weekDays = {DateTime.now().weekday};
      _endKind = RepeatEndKind.never;
      _count = 0;
      _until = null;
      _customRepeat = false;
    }
  }

  @override
  void dispose() {
    _draftDebounce?.cancel();
    _subject.dispose();
    _notes.dispose();
    _location.dispose();
    super.dispose();
  }

  /// Debounced ghost update for free-text fields. Date/time/repeat/people
  /// changes still call [_emitDraft] immediately (the ghost position
  /// matters); title/notes/location only affect the ghost label, so they
  /// can wait for a typing pause instead of rebuilding the calendar per
  /// keystroke.
  void _scheduleDraft() {
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) _emitDraft();
    });
  }

  @override
  void didUpdateWidget(covariant EventEditorForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.existing != null) return;
    var changed = false;
    if (widget.initialDate != oldWidget.initialDate &&
        widget.initialDate != null) {
      final next = widget.initialDate!;
      _date = DateTime(next.year, next.month, next.day);
      changed = true;
    }
    if (widget.initialTime != oldWidget.initialTime &&
        widget.initialTime != null) {
      _startTime = widget.initialTime!;
      if (_toMinutes(_endTime) <= _toMinutes(_startTime)) {
        _endTime = TimeOfDay(
          hour: (_startTime.hour + 1) % 24,
          minute: _startTime.minute,
        );
      }
      changed = true;
    }
    if (widget.initialEndTime != oldWidget.initialEndTime &&
        widget.initialEndTime != null) {
      _endTime = widget.initialEndTime!;
      changed = true;
    }
    if (changed) setState(() {});
  }

  void _emitDraft() {
    final onDraftChanged = widget.onDraftChanged;
    if (onDraftChanged == null) return;
    if (!mounted) return;
    final snap = context.read<SettingsCubit>().state.snapMinutes;
    final start = _allDay
        ? DateTime(_date.year, _date.month, _date.day)
        : snapToInterval(
            DateTime(_date.year, _date.month, _date.day, _startTime.hour,
                _startTime.minute),
            snap,
          );
    var end = _allDay
        ? start.add(const Duration(days: 1))
        : snapToInterval(
            DateTime(_date.year, _date.month, _date.day, _endTime.hour,
                _endTime.minute),
            snap,
          );
    if (end.isBefore(start) || end.isAtSameMomentAs(start)) {
      end = start.add(const Duration(hours: 1));
    }
    final config = RepeatConfig(
      kind: _repeatKind,
      weekDays: _weekDays,
      endKind: _endKind,
      count: _count,
      until: _until,
    );
    final existing = widget.existing;
    if (existing == null) {
      onDraftChanged(
        PlannerEvent(
          id: calendarDraftEventId,
          subject: _subject.text.trim(),
          notes:
              _notes.text.trim().isEmpty ? null : _notes.text.trim(),
          location: _location.text.trim().isEmpty
              ? null
              : _location.text.trim(),
          start: start,
          end: end,
          allDay: _allDay,
          recurrenceRule:
              _customRepeat ? '' : config.ruleFor(start),
          classLabel: widget.initialClassLabel,
          taskId: _sourceTaskId,
          isTask: _isTask,
          done: _isTask && _done,
          placeId: _placeId,
          assignees: _people,
        ),
      );
      return;
    }
    // Editing preview: carries the existing id so the calendar swaps the
    // tile in place. Times/label mirror [_save]'s computation so the
    // highlight matches what Save would write; the recurrence rule is
    // preserved so the preview can't re-expand the series.
    final subject = _subject.text.trim();
    final notes =
        _notes.text.trim().isEmpty ? null : _notes.text.trim();
    final location = _location.text.trim().isEmpty
        ? null
        : _location.text.trim();
    onDraftChanged(
      existing.copyWith(
        subject: subject.isEmpty ? existing.subject : subject,
        notes: notes,
        clearNotes: notes == null,
        location: location,
        clearLocation: location == null,
        start: start,
        end: end,
        allDay: _allDay,
        isTask: _isTask,
        done: _isTask && _done,
        placeId: _placeId,
        assignees: List.of(_people),
        reminderMinutesBefore: _reminderMinutesBefore,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {    final theme = Theme.of(context);
    // NB: no context.watch<FeedCubit>() here on purpose. The form used to
    // rebuild on every feed emission (sync status, background syncs), which
    // reset the calendar dropdown via its ValueKey and made the editor feel
    // glitchy. Only the picker below watches feeds now.
    final existing = widget.existing;
    return SafeArea(
      top: false,
      child: Stack(
        children: [
          SingleChildScrollView(
            controller: widget.scrollController,
            padding: const EdgeInsets.fromLTRB(16, 100, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_isSeriesInstance)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _loadingMaster
                          ? 'Loading series details…'
                          : 'Part of a repeating series — on save you can '
                              'apply changes to just this occurrence or the '
                              'entire series.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (_masterFailed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Couldn’t load the series — editing just this occurrence.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                _CalendarPicker(
                  existing: existing,
                  saveTargetFeedId: _saveTargetFeedId,
                  canChangeCalendar: (feeds) => existing == null
                      ? true
                      : _canChangeCalendar(existing, feeds),
                  onChanged: (value) =>
                      setState(() => _saveTargetFeedId = value),
                ),
                TextField(
                  controller: _subject,
                  autofocus: widget.autofocusTitle,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: _dateField(theme),
                    ),
                    const SizedBox(width: 8),
                    // Compact switch row instead of SwitchListTile: ListTile
                    // enforces its own min widths and overflows inside a tight
                    // Row on phones (~160px per side).
                    Expanded(
                      flex: 4,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Flexible(
                            child: Text(
                              'All day',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Switch(
                            value: _allDay,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            onChanged: (value) {
                              setState(() => _allDay = value);
                              _emitDraft();
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (!_allDay)
                  Row(
                    children: [
                      Expanded(
                        child: _timeField(
                          label: 'Start',
                          value: _startTime,
                          onChanged: (value) {
                            setState(() {
                              _startTime = value;
                              if (_toMinutes(_endTime) <= _toMinutes(_startTime)) {
                                _endTime = TimeOfDay(
                                  hour: (_startTime.hour + 1) % 24,
                                  minute: _startTime.minute,
                                );
                              }
                            });
                            _emitDraft();
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _timeField(
                          label: 'End',
                          value: _endTime,
                          onChanged: (value) {
                            setState(() => _endTime = value);
                            _emitDraft();
                          },
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                _DayConflictsSection(
                  day: _date,
                  allDay: _allDay,
                  startTime: _startTime,
                  endTime: _endTime,
                  excludeId: widget.existing?.id,
                ),
                const SizedBox(height: 12),
                _repeatSection(theme),
                const SizedBox(height: 12),
                ReminderField(
                  value: _reminderMinutesBefore,
                  onChanged: (value) {
                    setState(() => _reminderMinutesBefore = value);
                    _emitDraft();
                  },
                ),            const SizedBox(height: 12),
                TextField(
                  controller: _location,
                  decoration: const InputDecoration(
                    labelText: 'Location',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                _PlaceField(
                  value: _placeId,
                  onChanged: (value) {
                    setState(() => _placeId = value);
                    _emitDraft();
                  },
                ),
                const SizedBox(height: 12),
                PeopleField(
                  selected: _people,
                  onChanged: (value) {
                    setState(() => _people = value);
                    _emitDraft();
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _notes,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Task'),
                  subtitle: const Text(
                    'Tasks can be marked complete and show in the Tasks list',
                  ),
                  value: _isTask,
                  onChanged: (value) {
                    setState(() {
                      _isTask = value;
                      if (!value) _done = false;
                    });
                    _emitDraft();
                  },
                ),
                if (_isTask)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Completed'),
                    value: _done,
                    onChanged: (value) {
                      setState(() => _done = value ?? false);
                      _emitDraft();
                    },
                  ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: EventEditorActions(
              title: widget.title,
              hasExistingEvent: existing != null,
              allowDelete: widget.allowDelete,
              saving: _saving,
              onDelete: () => _delete(context),
              onCancel: widget.onCancelled,
              onSave: () => _save(context),
              saveLabel: existing == null ? 'Add' : 'Save',
            ),
          ),
        ],
      ),
    );
  }

  Widget _dateField(ThemeData theme) {
    final formatter = DateFormat('EEE, MMM d, yyyy');
    return InputDecorator(
      decoration: const InputDecoration(labelText: 'Date'),
      child: InkWell(
        onTap: () async {
          final picked = await showDatePicker(
            context: context,
            initialDate: _date,
            firstDate: DateTime(2000),
            lastDate: DateTime(2100),
          );
          if (picked != null) {
            setState(() => _date = picked);
            _emitDraft();
          }
        },
        child: Text(formatter.format(_date)),
      ),
    );
  }

  Widget _timeField({
    required String label,
    required TimeOfDay value,
    required ValueChanged<TimeOfDay> onChanged,
  }) {
    return InputDecorator(
      decoration: InputDecoration(labelText: label),
      child: InkWell(
        onTap: () async {
          final picked = await showTimePicker(
            context: context,
            initialTime: value,
          );
          if (picked != null) onChanged(picked);
        },
        child: Text(value.format(context)),
      ),
    );
  }

  Widget _repeatSection(ThemeData theme) {
    if (_customRepeat) {
      return InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Repeat',
          helperText: 'Custom repeat rule from source feed (unchanged)',
        ),
        child: const Text('Custom'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<RepeatKind>(
          initialValue: _repeatKind,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Repeat',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: RepeatKind.none, child: Text('Does not repeat')),
            DropdownMenuItem(value: RepeatKind.daily, child: Text('Daily')),
            DropdownMenuItem(value: RepeatKind.weekdays, child: Text('Every weekday')),
            DropdownMenuItem(value: RepeatKind.weekly, child: Text('Weekly on selected days')),
            DropdownMenuItem(value: RepeatKind.biweekly, child: Text('Every 2 weeks')),
            DropdownMenuItem(value: RepeatKind.monthly, child: Text('Monthly')),
            DropdownMenuItem(value: RepeatKind.yearly, child: Text('Yearly')),
          ],
          onChanged: (value) {
            setState(() {
              _repeatKind = value ?? RepeatKind.none;
              _repeatTouched = true;
            });
            _emitDraft();
          },
        ),
        if (_repeatKind == RepeatKind.weekly ||
            _repeatKind == RepeatKind.biweekly) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: [
              for (final day in const [1, 2, 3, 4, 5, 6, 7])
                FilterChip(
                  label: Text(_dayLabel(day)),
                  selected: _weekDays.contains(day),
                  onSelected: (selected) {
                    setState(() {
                      if (selected) {
                        _weekDays.add(day);
                      } else {
                        _weekDays.remove(day);
                        if (_weekDays.isEmpty) _weekDays.add(day);
                      }
                      _repeatTouched = true;
                    });
                    _emitDraft();
                  },
                ),
            ],
          ),
        ],
        if (_repeatKind != RepeatKind.none) ...[
          const SizedBox(height: 8),
          // Horizontal scroll instead of forcing the three segments into
          // the available width: on phones (~328px) SegmentedButton
          // otherwise throws a RenderFlex pixel overflow.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<RepeatEndKind>(
              segments: const [
                ButtonSegment(value: RepeatEndKind.never, label: Text('Forever')),
                ButtonSegment(value: RepeatEndKind.after, label: Text('N times')),
                ButtonSegment(value: RepeatEndKind.until, label: Text('Until')),
              ],
              selected: {_endKind},
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onSelectionChanged: (selection) {
                setState(() {
                  _endKind = selection.first;
                  _repeatTouched = true;
                });
                _emitDraft();
              },
            ),
          ),
          if (_endKind == RepeatEndKind.after)
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                const Text('Repeats'),
                SizedBox(
                  width: 80,
                  child: TextFormField(
                    initialValue: _count > 0 ? '$_count' : '',
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(hintText: '10'),
                    onChanged: (value) {
                      setState(() {
                        _count = int.tryParse(value) ?? 0;
                        _repeatTouched = true;
                      });
                      _emitDraft();
                    },
                  ),
                ),
                const Text('times'),
              ],
            ),
          if (_endKind == RepeatEndKind.until)
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                Flexible(
                  child: Text(
                    _until == null
                        ? 'Until date not set'
                        : DateFormat('EEE, MMM d, yyyy').format(_until!),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _until ?? _date.add(const Duration(days: 30)),
                      firstDate: _date,
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) {
                      setState(() {
                        _until = picked;
                        _repeatTouched = true;
                      });
                      _emitDraft();
                    }
                  },
                  child: const Text('Pick'),
                ),
              ],
            ),
        ],
      ],
    );
  }

  static int _toMinutes(TimeOfDay time) => time.hour * 60 + time.minute;

  static String _dayLabel(int weekday) => switch (weekday) {
        DateTime.monday => 'M',
        DateTime.tuesday => 'T',
        DateTime.wednesday => 'W',
        DateTime.thursday => 'T',
        DateTime.friday => 'F',
        DateTime.saturday => 'S',
        DateTime.sunday => 'S',
        _ => '?',
      };

  void _save(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final feedCubit = context.read<FeedCubit>();
    final calendarCubit = context.read<CalendarCubit>();
    // Captured before any async gap: the lint (and a real crash) fires when
    // `context.read` runs after an await with only a State.mounted guard,
    // since the passed BuildContext may be unmounted while State is alive.
    NodeCubit? nodeCubit;
    try {
      nodeCubit = context.read<NodeCubit>();
    } catch (_) {}
    final subject = _subject.text.trim();
    if (subject.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Please enter a title')),
      );
      return;
    }
    final snap = context.read<SettingsCubit>().state.snapMinutes;
    final start = _allDay
        ? DateTime(_date.year, _date.month, _date.day)
        : snapToInterval(
            DateTime(_date.year, _date.month, _date.day, _startTime.hour,
                _startTime.minute),
            snap,
          );
    var end = _allDay
        ? start.add(const Duration(days: 1))
        : snapToInterval(
            DateTime(_date.year, _date.month, _date.day, _endTime.hour,
                _endTime.minute),
            snap,
          );
    if (end.isBefore(start) || end.isAtSameMomentAs(start)) {
      end = start.add(const Duration(hours: 1));
    }
    final config = RepeatConfig(
      kind: _repeatKind,
      weekDays: _weekDays,
      endKind: _endKind,
      count: _count,
      until: _until,
    );
    final notes =
        _notes.text.trim().isEmpty ? null : _notes.text.trim();
    final location =
        _location.text.trim().isEmpty ? null : _location.text.trim();
    final done = _isTask && _done;
    if (widget.existing == null) {
      final rule = _customRepeat ? '' : config.ruleFor(start);
      final draft = PlannerEvent(
        id: 'evt:${DateTime.now().microsecondsSinceEpoch}',
        subject: subject,
        notes: notes,
        location: location,
        start: start,
        end: end,
        allDay: _allDay,
        recurrenceRule: rule,
        taskId: _sourceTaskId,
        isTask: _isTask,
        done: done,
        completedAt: done ? DateTime.now() : null,
        assignees: _people,
        placeId: _placeId,
        reminderMinutesBefore: _reminderMinutesBefore,
      );
      final targetFeed = feedCubit.byId(_saveTargetFeedId ?? '');
      if (targetFeed != null) {
        setState(() => _saving = true);
        final result = await feedCubit.pushEventCreate(
            feed: targetFeed, event: draft);
        if (!mounted) return;
        setState(() => _saving = false);
        if (result.error != null) {
          messenger.showSnackBar(
            SnackBar(content: Text(result.error!)),
          );
          return;
        }
        if (_sourceTaskId != null) {
          final createdId = result.created?.id;
          if (createdId != null) {
            try {
              nodeCubit?.setCalendarEvent(
                _sourceTaskId!,
                createdId,
              );
            } catch (_) {}
          }
        }
        _applyLocalAssignees(result.created?.id ?? draft.id);
        _mirrorAssigneesToSourceTask();
        _applyTaskLinkPostSync(result.created?.id ?? draft.id);
        _restoreReminder(result.created?.id ?? draft.id);
        await EventReminderService.scheduleReminder(
          calendarCubit.byId(result.created?.id ?? draft.id) ?? draft,
        );
        if (!context.mounted) return;
        final savedForPrompt =
            calendarCubit.byId(result.created?.id ?? draft.id) ?? draft;
        await maybePromptForEventReminder(
          context,
          savedForPrompt,
          calendar: calendarCubit,
        );
        if (!context.mounted) return;
        widget.onFinished?.call();
        return;
      }
      calendarCubit.addEvent(draft);
      if (_sourceTaskId != null) {
        try {
          nodeCubit?.setCalendarEvent(_sourceTaskId!, draft.id);
        } catch (_) {}
      }
      _syncTaskLink(draft);
      await EventReminderService.scheduleReminder(draft);
      if (!context.mounted) return;
      await maybePromptForEventReminder(
        context,
        draft,
        calendar: calendarCubit,
      );
      if (!context.mounted) return;
      widget.onFinished?.call();
      return;
    }
    final base = calendarCubit.byId(widget.existing!.id) ?? widget.existing!;
    final ruleForMove =
        _customRepeat ? base.recurrenceRule : config.ruleFor(start);
    if (_canChangeCalendar(base, feedCubit)) {
      final destFeedId = feedCubit.byId(_saveTargetFeedId ?? '')?.kind ==
              FeedKind.google
          ? _saveTargetFeedId
          : null;
      final origFeedId = base.feedId;
      final calendarChanged = (destFeedId ?? '') != (origFeedId ?? '');
      if (calendarChanged) {
        await _moveEvent(
          context,
          base: base,
          destFeedId: destFeedId,
          subject: subject,
          notes: notes,
          location: location,
          start: start,
          end: end,
          rule: ruleForMove,
          done: done,
        );
        return;
      }
    }
    // Repeating Google instances get a Google-style scope choice: just
    // this occurrence, or the entire series.
    if (base.isRecurringInstance && feedCubit.isRemoteEditable(base)) {
      await _saveRecurringInstance(
        context,
        base: base,
        subject: subject,
        notes: notes,
        location: location,
        start: start,
        end: end,
        done: done,
        config: config,
      );
      return;
    }
    final rule = _customRepeat ? base.recurrenceRule : config.ruleFor(start);
    final updated = base.copyWith(
      subject: subject,
      notes: notes,
      clearNotes: notes == null,
      location: location,
      clearLocation: location == null,
      start: start,
      end: end,
      allDay: _allDay,
      recurrenceRule: rule,
      isTask: _isTask,
      done: done,
      completedAt: done && !base.done ? DateTime.now() : null,
      clearCompletedAt: !done,
      placeId: _placeId,
      clearPlaceId: _placeId == null,
      assignees: _people,
      reminderMinutesBefore: _reminderMinutesBefore,
      clearReminder: _reminderMinutesBefore == null,
    );
    if (feedCubit.isRemoteEditable(base)) {
      // Local-only changes (task flag, people, place, completion) never
      // touch Google: the task flag is local-only, so pushing would at
      // best waste a round trip and at worst fail the whole save.
      if (!_googleVisibleChanged(
        base,
        subject: subject,
        notes: notes,
        location: location,
        start: start,
        end: end,
        allDay: _allDay,
      )) {
        calendarCubit.updateEvent(updated);
        _syncTaskLink(updated);
        await EventReminderService.scheduleReminder(updated);
        widget.onFinished?.call();
        return;
      }
      setState(() => _saving = true);
      final error = await feedCubit.pushEventUpdate(updated);
      if (!mounted) return;
      setState(() => _saving = false);
      if (error != null) {
        messenger.showSnackBar(
          SnackBar(content: Text(error)),
        );
        return;
      }
      _applyLocalAssignees(updated.id);
      _syncTaskLinkPostPush(updated.id);
      _restoreReminder(updated.id);
      await EventReminderService.scheduleReminder(
        calendarCubit.byId(updated.id) ?? updated,
      );
      widget.onFinished?.call();
      return;
    }
    calendarCubit.updateEvent(updated);
    _syncTaskLink(updated);
    await EventReminderService.scheduleReminder(updated);
    widget.onFinished?.call();
  }

  /// Moves an edited event between "This device" (null) and a Google
  /// calendar, or between two Google calendars. Implemented as create in
  /// the destination + delete from the source using the existing push
  /// endpoints, so no server change is needed. Local-only state (task
  /// flag, people, place) is re-asserted on the new copy; backing tasks
  /// for the old id are removed.
  Future<void> _moveEvent(
    BuildContext context, {
    required PlannerEvent base,
    required String? destFeedId,
    required String subject,
    required String? notes,
    required String? location,
    required DateTime start,
    required DateTime end,
    required String rule,
    required bool done,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final feedCubit = context.read<FeedCubit>();
    final calendarCubit = context.read<CalendarCubit>();
    NodeCubit? nodeCubit;
    try {
      nodeCubit = context.read<NodeCubit>();
    } catch (_) {}
    final nodes = nodeCubit;

    if (destFeedId == null) {
      // Google → This device: snapshot locally first (never loses data),
      // then delete the remote copy.
      final now = DateTime.now();
      final completedAt =
          done ? (base.done ? base.completedAt ?? now : now) : null;
      final local = PlannerEvent(
        id: 'evt:${DateTime.now().microsecondsSinceEpoch}',
        subject: subject,
        notes: notes,
        location: location,
        start: start,
        end: end,
        allDay: _allDay,
        recurrenceRule: rule,
        taskId: _sourceTaskId,
        isTask: _isTask,
        done: done,
        completedAt: completedAt,
        placeId: _placeId,
        assignees: List.of(_people),
        reminderMinutesBefore:
            _reminderMinutesBefore ?? base.reminderMinutesBefore,
      );
      setState(() => _saving = true);
      calendarCubit.addEvent(local);
      if (_sourceTaskId != null && nodes != null) {
        try {
          nodes.setCalendarEvent(_sourceTaskId!, local.id);
        } catch (_) {}
      }
      _syncTaskLink(local);
      await EventReminderService.scheduleReminder(local);
      final error = await feedCubit.pushEventDelete(base);
      if (!mounted) return;
      setState(() => _saving = false);
      if (error != null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Saved to this device, but couldn’t remove the Google copy: $error',
            ),
          ),
        );
        widget.onFinished?.call();
        return;
      }
      if (nodes != null) {
        try {
          nodes.removeNodesForEvent(base.id);
          nodes.clearCalendarEventForEvent(base.id);
        } catch (_) {}
      }
      widget.onFinished?.call();
      return;
    }

    final destFeed = feedCubit.byId(destFeedId);
    if (destFeed == null ||
        destFeed.kind != FeedKind.google ||
        destFeed.calendarId == null ||
        destFeed.calendarId!.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Choose a Google calendar to move to.')),
      );
      return;
    }
    final now = DateTime.now();
    final draft = PlannerEvent(
      id: 'evt:${DateTime.now().microsecondsSinceEpoch}',
      subject: subject,
      notes: notes,
      location: location,
      start: start,
      end: end,
      allDay: _allDay,
      recurrenceRule: rule,
      taskId: _sourceTaskId,
      isTask: _isTask,
      done: done,
      completedAt: done ? (base.done ? base.completedAt ?? now : now) : null,
      placeId: _placeId,
      assignees: List.of(_people),
      reminderMinutesBefore:
          _reminderMinutesBefore ?? base.reminderMinutesBefore,
    );
    setState(() => _saving = true);
    final result =
        await feedCubit.pushEventCreate(feed: destFeed, event: draft);
    if (!mounted) return;
    if (result.error != null) {
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text(result.error!)));
      return;
    }
    final newId = result.created?.id ?? draft.id;
    if (_sourceTaskId != null && nodes != null) {
      try {
        nodes.setCalendarEvent(_sourceTaskId!, newId);
      } catch (_) {}
    }
    _applyLocalAssignees(newId);
    _restorePlaceId(newId);
    _restoreReminder(newId);
    _mirrorAssigneesToSourceTask();
    _applyTaskLinkPostSync(newId);
    await EventReminderService.scheduleReminder(
      calendarCubit.byId(newId) ?? draft,
    );
    if (base.isFromFeed) {
      final deleteError = await feedCubit.pushEventDelete(base);
      if (!mounted) return;
      setState(() => _saving = false);
      if (deleteError != null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Saved to ${destFeed.name}, but couldn’t remove the original: $deleteError',
            ),
          ),
        );
        widget.onFinished?.call();
        return;
      }
      if (nodes != null) {
        try {
          nodes.removeNodesForEvent(base.id);
          nodes.clearCalendarEventForEvent(base.id);
        } catch (_) {}
      }
    } else {
      calendarCubit.deleteEvent(base.id);
      if (nodes != null) {
        try {
          nodes.removeNodesForEvent(base.id);
          nodes.clearCalendarEventForEvent(base.id);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() => _saving = false);
    }
    widget.onFinished?.call();
  }

  /// Re-asserts the editor's place on the freshly synced Google copy.
  /// Google never stores it, so without this a calendar move (or any
  /// push + re-sync) would drop the user's pick.
  void _restorePlaceId(String eventId) {
    if (_placeId == null) return;
    CalendarCubit calendar;
    try {
      calendar = context.read<CalendarCubit>();
    } catch (_) {
      return;
    }
    final synced = calendar.byId(eventId);
    if (synced == null || synced.placeId == _placeId) return;
    calendar.updateEvent(synced.copyWith(placeId: _placeId));
  }

  /// Re-asserts the editor's reminder on the freshly synced Google copy.
  /// Reminders are device-local (Google never stores them), so without
  /// this a push + re-sync would drop the user's pick.
  void _restoreReminder(String eventId) {
    final reminder = _reminderMinutesBefore;
    if (reminder == null) return;
    CalendarCubit calendar;
    try {
      calendar = context.read<CalendarCubit>();
    } catch (_) {
      return;
    }
    final synced = calendar.byId(eventId);
    if (synced == null || synced.reminderMinutesBefore == reminder) return;
    calendar.updateEvent(synced.copyWith(reminderMinutesBefore: reminder));
  }

  static bool _sameOpt(String? a, String? b) => (a ?? '') == (b ?? '');

  bool _googleVisibleChanged(
    PlannerEvent base, {
    required String subject,
    required String? notes,
    required String? location,
    required DateTime start,
    required DateTime end,
    required bool allDay,
  }) {
    if (base.subject != subject) return true;
    if (!_sameOpt(base.notes, notes)) return true;
    if (!_sameOpt(base.location, location)) return true;
    if (base.start != start || base.end != end) return true;
    if (base.allDay != allDay) return true;
    return false;
  }

  Future<void> _saveRecurringInstance(
    BuildContext context, {
    required PlannerEvent base,
    required String subject,
    required String? notes,
    required String? location,
    required DateTime start,
    required DateTime end,
    required bool done,
    required RepeatConfig config,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final feedCubit = context.read<FeedCubit>();
    final calendarCubit = context.read<CalendarCubit>();
    var scope = _EditChoice.occurrence;
    if (!_masterFailed) {
      final choice = await showDialog<_EditChoice>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Edit repeating event'),
          content: const Text(
            'Apply changes to just this occurrence, or the entire series?',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_EditChoice.cancel),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext)
                  .pop(_EditChoice.occurrence),
              child: const Text('This occurrence'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_EditChoice.series),
              child: const Text('Entire series'),
            ),
          ],
        ),
      );
      if (choice == null || choice == _EditChoice.cancel) return;
      scope = choice;
    }
    if (!context.mounted) return;
    if (scope == _EditChoice.series) {
      await _saveSeries(
        context,
        base: base,
        subject: subject,
        notes: notes,
        location: location,
        done: done,
        config: config,
      );
      return;
    }
    // Single-occurrence save. The instance patch strips recurrence on the
    // way out, so the form's repeat UI is irrelevant here.
    final updated = base.copyWith(
      subject: subject,
      notes: notes,
      clearNotes: notes == null,
      location: location,
      clearLocation: location == null,
      start: start,
      end: end,
      allDay: _allDay,
      isTask: _isTask,
      done: done,
      completedAt: done && !base.done ? DateTime.now() : null,
      clearCompletedAt: !done,
      placeId: _placeId,
      clearPlaceId: _placeId == null,
      assignees: _people,
      reminderMinutesBefore: _reminderMinutesBefore,
      clearReminder: _reminderMinutesBefore == null,
    );
    if (!_googleVisibleChanged(
      base,
      subject: subject,
      notes: notes,
      location: location,
      start: start,
      end: end,
      allDay: _allDay,
    )) {
      // Task/assignee-only change: local update, no Google round trip, so
      // marking a repeating event as a task can't fail to save.
      calendarCubit.updateEvent(updated);
      _syncTaskLink(updated);
      await EventReminderService.scheduleReminder(updated);
      widget.onFinished?.call();
      return;
    }
    setState(() => _saving = true);
    final error = await feedCubit.pushEventUpdate(updated);
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    _applyLocalAssignees(updated.id);
    _syncTaskLinkPostPush(updated.id);
    _restoreReminder(updated.id);
    await EventReminderService.scheduleReminder(
      calendarCubit.byId(updated.id) ?? updated,
    );
    widget.onFinished?.call();
  }

  Future<void> _saveSeries(
    BuildContext context, {
    required PlannerEvent base,
    required String subject,
    required String? notes,
    required String? location,
    required bool done,
    required RepeatConfig config,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final feedCubit = context.read<FeedCubit>();
    var master = _seriesMaster;
    if (master == null && !_masterFailed) {
      setState(() => _saving = true);
      try {
        master = await feedCubit.fetchSeriesMaster(base);
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      if (!context.mounted) return;
      if (master != null) {
        setState(() => _seriesMaster = master);
      }
    }
    if (master == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Couldn’t load the series — try just this occurrence.'),
        ),
      );
      return;
    }
    final seriesRule = _customRepeat
        ? master.recurrenceRule
        : (_repeatTouched ? config.ruleFor(_masterDateStart(master)) : master.recurrenceRule);
    final seriesStart = _masterStart(master);
    final seriesEnd = _masterEnd(master, seriesStart);
    final googleChanged = master.subject != subject ||
        !_sameOpt(master.notes, notes) ||
        !_sameOpt(master.location, location) ||
        master.allDay != _allDay ||
        _toMinutes(TimeOfDay.fromDateTime(master.start)) !=
            _toMinutes(_startTime) ||
        _toMinutes(TimeOfDay.fromDateTime(
              master.end.isAfter(master.start)
                  ? master.end
                  : master.start.add(const Duration(hours: 1)),
            )) !=
            _toMinutes(_endTime) ||
        master.recurrenceRule != seriesRule;
    if (!googleChanged) {
      _applySeriesLocal(
        master,
        done: done,
        editedId: base.id,
      );
      widget.onFinished?.call();
      return;
    }
    final updatedMaster = master.copyWith(
      subject: subject,
      notes: notes,
      clearNotes: notes == null,
      location: location,
      clearLocation: location == null,
      start: seriesStart,
      end: seriesEnd,
      allDay: _allDay,
      recurrenceRule: seriesRule,
    );
    setState(() => _saving = true);
    final error =
        await feedCubit.pushEventUpdate(updatedMaster, series: true);
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    _applySeriesPostPush(master, done: done, editedId: base.id);
    widget.onFinished?.call();
  }

  DateTime _masterDateStart(PlannerEvent master) => DateTime(
        master.start.year,
        master.start.month,
        master.start.day,
        _startTime.hour,
        _startTime.minute,
      );

  DateTime _masterStart(PlannerEvent master) {
    if (_allDay) {
      return DateTime(master.start.year, master.start.month, master.start.day);
    }
    return _masterDateStart(master);
  }

  DateTime _masterEnd(PlannerEvent master, DateTime seriesStart) {
    if (_allDay) return seriesStart.add(const Duration(days: 1));
    final candidate = DateTime(
      master.start.year,
      master.start.month,
      master.start.day,
      _endTime.hour,
      _endTime.minute,
    );
    if (!candidate.isAfter(seriesStart)) {
      return seriesStart.add(const Duration(hours: 1));
    }
    return candidate;
  }

  /// Local-only series update: applies the editor's task/people/place
  /// state to the series' future occurrences and mirrors each into its
  /// backing node. Past occurrences stay plain calendar events (no backing
  /// nodes): marking a series that has been repeating for a while must not
  /// flood the Tasks list with an overdue todo per past occurrence. No
  /// Google write.
  ///
  /// Batched into a handful of emits (one per cubit): looping the
  /// single-write methods snapshots the whole store per occurrence and
  /// kills the tab on large calendars.
  void _applySeriesLocal(PlannerEvent master,
      {required bool done, String? editedId}) {
    CalendarCubit calendar;
    NodeCubit nodes;
    try {
      calendar = context.read<CalendarCubit>();
      nodes = context.read<NodeCubit>();
    } catch (_) {
      return;
    }
    final key =
        FeedCubit.seriesRemoteId(master) ?? FeedCubit.seriesKeyFor(master);
    if (key == null) return;
    final completedAt = done ? DateTime.now() : null;
    final members = [
      for (final event in calendar.state)
        if (FeedCubit.seriesKeyFor(event) == key) event,
    ];
    if (members.isEmpty) return;
    final now = DateTime.now();
    // The occurrence the user edited is always a target, even when it is
    // itself in the past — the toggle was flipped on it explicitly. Every
    // other past occurrence is left out of the task set.
    bool isTarget(PlannerEvent event) =>
        event.id == editedId ||
        NodeEventLink.isFutureOccurrence(event, now);
    final targets = [for (final event in members) if (isTarget(event)) event];
    final past = [for (final event in members) if (!isTarget(event)) event];
    calendar.updateEvents([
      for (final event in targets)
        event.copyWith(
          isTask: _isTask,
          done: done,
          completedAt: completedAt,
          clearCompletedAt: !done,
          placeId: _placeId,
          clearPlaceId: _placeId == null,
          assignees: List.of(_people),
          reminderMinutesBefore: _reminderMinutesBefore,
          clearReminder: _reminderMinutesBefore == null,
        ),
      // Past occurrences keep people/place in sync but never stay tasks,
      // so a series marked today can't leave overdue todos behind — even
      // ones created by an earlier whole-series mark.
      for (final event in past)
        if (event.isTask ||
            event.done ||
            event.completedAt != null ||
            !_sameAssignees(event.assignees, _people))
          event.copyWith(
            isTask: false,
            done: false,
            clearCompletedAt: true,
            placeId: _placeId,
            clearPlaceId: _placeId == null,
            assignees: List.of(_people),
            reminderMinutesBefore: _reminderMinutesBefore,
            clearReminder: _reminderMinutesBefore == null,
          ),
    ]);
    final pastIds = {for (final e in past) e.id};
    if (!_isTask) {
      nodes.removeNodesForEventIds(
          {for (final e in members) e.id},
          silent: true);
      return;
    }
    nodes.ensureNodesForFeedEvents([
      for (final event in targets)
        event.copyWith(
          isTask: true,
          done: done,
          completedAt: completedAt,
          clearCompletedAt: !done,
          placeId: _placeId,
          clearPlaceId: _placeId == null,
          assignees: List.of(_people),
          reminderMinutesBefore: _reminderMinutesBefore,
          clearReminder: _reminderMinutesBefore == null,
        ),
    ]);
    nodes.setDoneForEventIds(
      {for (final e in targets) e.id},
      done: done,
      completedAt: completedAt,
      taskIdsByEvent: {for (final e in targets) e.id: e.taskId},
    );
    nodes.removeNodesForEventIds(pastIds, silent: true);
  }

  /// Post-push series fix-up: the Google re-sync drops local-only state,
  /// so re-assert node/people/place on the series' future occurrences.
  /// Past occurrences are un-marked for the same reason as in
  /// [_applySeriesLocal]. Batched like [_applySeriesLocal] for the same
  /// storm reason.
  void _applySeriesPostPush(PlannerEvent master,
      {required bool done, String? editedId}) {
    CalendarCubit calendar;
    NodeCubit nodes;
    try {
      calendar = context.read<CalendarCubit>();
      nodes = context.read<NodeCubit>();
    } catch (_) {
      return;
    }
    final key =
        FeedCubit.seriesRemoteId(master) ?? FeedCubit.seriesKeyFor(master);
    if (key == null) return;
    final completedAt = done ? DateTime.now() : null;
    final members = [
      for (final event in calendar.state)
        if (FeedCubit.seriesKeyFor(event) == key) event,
    ];
    if (members.isEmpty) return;
    final now = DateTime.now();
    bool isTarget(PlannerEvent event) =>
        event.id == editedId ||
        NodeEventLink.isFutureOccurrence(event, now);
    final targets = [for (final event in members) if (isTarget(event)) event];
    final past = [for (final event in members) if (!isTarget(event)) event];
    final targetIds = {for (final e in targets) e.id};
    final calUpdates = <PlannerEvent>[];
    for (final event in members) {
      final pastEvent = !targetIds.contains(event.id);
      var current = event;
      if (!_sameAssignees(current.assignees, _people)) {
        current = current.copyWith(assignees: List.of(_people));
      }
      if (!_isTask || pastEvent) {
        if (current.isTask) {
          current = current.copyWith(
            isTask: false,
            done: false,
            clearCompletedAt: true,
          );
        }
      } else {
        final marked = current.copyWith(
          isTask: true,
          done: done,
          completedAt: completedAt,
          clearCompletedAt: !done,
          placeId: _placeId,
          clearPlaceId: _placeId == null,
          assignees: List.of(_people),
          reminderMinutesBefore: _reminderMinutesBefore,
          clearReminder: _reminderMinutesBefore == null,
        );
        if (marked != current) current = marked;
      }
      if (current != event) calUpdates.add(current);
    }
    calendar.updateEvents(calUpdates);
    if (!_isTask) {
      nodes.removeNodesForEventIds(
          {for (final e in members) e.id},
          silent: true);
      return;
    }
    // The re-sync may have dropped the mark the push just set, so the
    // ensure input carries the full local state (mirrors the old
    // per-member `marked` exactly, including members needing no
    // calendar change).
    final markedById = {for (final e in calUpdates) e.id: e};
    nodes.ensureNodesForFeedEvents([
      for (final event in targets) markedById[event.id] ?? event,
    ]);
    nodes.setDoneForEventIds(
      targetIds,
      done: done,
      completedAt: completedAt,
      taskIdsByEvent: {
        for (final id in targetIds) id: calendar.byId(id)?.taskId,
      },
    );
    nodes.removeNodesForEventIds(
        {for (final e in past) e.id},
        silent: true);
  }

  /// Mirrors a locally saved event's task flag into [NodeCubit]: creates or
  /// refreshes the backing node when marked, removes backing nodes when
  /// un-marked.
  void _syncTaskLink(PlannerEvent saved) {
    NodeCubit nodes;
    try {
      nodes = context.read<NodeCubit>();
    } catch (_) {
      return;
    }
    final calendar = context.read<CalendarCubit>();
    if (!saved.isTask) {
      final seeded = _seededSourceNode(nodes, saved.id, saved.taskId);
      if (seeded != null) {
        // The Task switch describes the event, not the assignment it was
        // scheduled from: turning it off must not delete that task. The
        // block the user just picked is still that task's plan, so the
        // task list keeps showing it as scheduled.
        nodes.setScheduleBlock(seeded.id, saved.start, saved.end);
        return;
      }
      nodes.removeNodesForEvent(saved.id);
      return;
    }
    if (saved.isFromFeed) {
      nodes.ensureNodeForFeedEvent(saved);
      nodes.setDoneForEvent(
        saved.id,
        done: saved.done,
        completedAt: saved.completedAt,
        taskId: saved.taskId,
      );
      return;
    }
    final nodeId = nodes.upsertLinkedNodeForEvent(saved);
    calendar.setTaskLink(saved.id, nodeId);
    nodes.setDoneForEvent(
      saved.id,
      done: saved.done,
      completedAt: saved.completedAt,
      taskId: saved.taskId ?? nodeId,
    );
  }

  /// The pre-existing task that seeded this event ("Add to calendar"),
  /// when it is still linked to it. Never the synthetic `node:<id>`
  /// backing that [NodeCubit.upsertLinkedNodeForEvent] creates for an
  /// event marked as a task itself — that one is disposable.
  static Node? _seededSourceNode(
    NodeCubit nodes,
    String eventId,
    String? linkedId,
  ) {
    if (linkedId == null || linkedId == 'node:$eventId') return null;
    final node = nodes.byId(linkedId);
    if (node == null || node.calendarEventId != eventId) return null;
    return node;
  }

  /// Re-applies the editor's task flag after a Google push + re-sync, which
  /// otherwise drops the local-only [PlannerEvent.isTask] state.
  /// Handles both marking and un-marking: an un-check must clear the
  /// resync-restored flag and its backing nodes.
  void _applyTaskLinkPostSync(String syncedId) {
    NodeCubit nodes;
    CalendarCubit calendar;
    try {
      nodes = context.read<NodeCubit>();
      calendar = context.read<CalendarCubit>();
    } catch (_) {
      return;
    }
    if (!_isTask) {
      if (_seededSourceNode(nodes, syncedId, _sourceTaskId) != null) {
        // Scheduling an assignment must not delete it, even when the user
        // saved the calendar block as a plain event.
        return;
      }
      NodeEventLink.unmarkEventAsNode(calendar, nodes, syncedId);
      return;
    }
    NodeEventLink.markEventAsNode(calendar, nodes, syncedId);
    // The block the user picked is the source task's plan as well. Google
    // holds the time; the task keeps its own due date.
    final seeded = _seededSourceNode(nodes, syncedId, _sourceTaskId);
    final synced = calendar.byId(syncedId);
    if (seeded != null && synced != null) {
      nodes.setScheduleBlock(seeded.id, synced.start, synced.end);
    }
    // Re-assert completion both ways: the re-sync can restore a stale
    // done flag either direction, so an un-check must re-open the backing
    // task just as a check must complete it (idempotent when already in
    // agreement — see the task_tracking_link_test "sticks" cases).
    NodeEventSync.setEventDone(
      calendar,
      nodes,
      syncedId,
      done: _done,
    );
  }

  void _syncTaskLinkPostPush(String syncedId) =>
      _applyTaskLinkPostSync(syncedId);

  static bool _sameAssignees(
      List<TaskAssignee> a, List<TaskAssignee> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Writes the editor's people onto the freshly synced local event. Google
  /// never stores assignees, so without this the post-push re-sync would
  /// restore the pre-edit (empty) list and drop the user's picks.
  /// Must run before [_applyTaskLinkPostSync] so backing tasks pick them up.
  void _applyLocalAssignees(String eventId) {
    CalendarCubit calendar;
    try {
      calendar = context.read<CalendarCubit>();
    } catch (_) {
      return;
    }
    final synced = calendar.byId(eventId);
    if (synced == null) return;
    if (_sameAssignees(synced.assignees, _people)) return;
    calendar.updateEvent(synced.copyWith(assignees: List.of(_people)));
  }

  /// Mirrors the editor's people onto the source node a new event was
  /// created from. Skipped when nothing changed (the common case: the
  /// picker was seeded from the node).
  void _mirrorAssigneesToSourceTask() {
    final sourceId = _sourceTaskId;
    if (sourceId == null) return;
    NodeCubit nodes;
    try {
      nodes = context.read<NodeCubit>();
    } catch (_) {
      return;
    }
    final source = nodes.byId(sourceId);
    if (source == null) return;
    if (_sameAssignees(source.assignees, _people)) return;
    nodes.updateNode(source.copyWith(assignees: List.of(_people)));
  }

  void _delete(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final undoCubit = context.read<UndoCubit>();
    final feedCubit = context.read<FeedCubit>();
    final calendarCubit = context.read<CalendarCubit>();
    final existing = widget.existing;
    if (existing == null) return;
    void clearTaskLink({bool wholeSeries = false}) {
      try {
        final nodeCubit = context.read<NodeCubit>();
        if (!wholeSeries) {
          if (existing.taskId != null) {
            nodeCubit.clearCalendarEvent(existing.taskId!);
          }
          nodeCubit.clearCalendarEventForEvent(existing.id);
          nodeCubit.removeNodesForEvent(existing.id);
          return;
        }
        final key = FeedCubit.seriesRemoteId(existing) ??
            FeedCubit.seriesKeyFor(existing);
        final ids = <String>{existing.id};
        if (key != null) {
          for (final event in calendarCubit.state) {
            if (FeedCubit.seriesKeyFor(event) == key) ids.add(event.id);
          }
        }
        for (final id in ids) {
          nodeCubit.clearCalendarEventForEvent(id);
          nodeCubit.removeNodesForEvent(id);
        }
        if (existing.taskId != null) {
          nodeCubit.clearCalendarEvent(existing.taskId!);
        }
      } catch (_) {}
    }

    if (!feedCubit.isRemoteEditable(existing)) {
      NodeCubit? nodes;
      try {
        nodes = context.read<NodeCubit>();
      } catch (_) {}
      if (nodes == null) {
        calendarCubit.deleteEvent(existing.id);
      } else {
        NodeEventLink.deleteEventAndNodes(calendarCubit, nodes, existing);
      }
      await EventReminderService.cancelReminder(existing.id);
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          persist: false,
          content: const Text('Event deleted'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: undoCubit.undo,
          ),
        ),
      );
      widget.onFinished?.call();
      return;
    }
    var series = false;
    if (existing.isRecurringInstance) {
      final choice = await showDialog<_DeleteChoice>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Delete repeating event'),
          content: const Text(
            'Delete just this occurrence, or the entire series?',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_DeleteChoice.cancel),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext)
                  .pop(_DeleteChoice.occurrence),
              child: const Text('This occurrence'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_DeleteChoice.series),
              child: const Text('Entire series'),
            ),
          ],
        ),
      );
      if (choice == null || choice == _DeleteChoice.cancel) return;
      series = choice == _DeleteChoice.series;
    }
    if (!context.mounted) return;
    setState(() => _saving = true);
    final error =
        await feedCubit.pushEventDelete(existing, series: series);
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(error)),
      );
      return;
    }
    clearTaskLink(wholeSeries: series);
    await EventReminderService.cancelReminder(existing.id);
    widget.onFinished?.call();
  }
}

enum _DeleteChoice { cancel, occurrence, series }

enum _EditChoice { cancel, occurrence, series }

/// Calendar picker isolated from [EventEditorFormState.build] so feed syncs
/// (status/last-sync emissions) only rebuild this dropdown, not the whole
/// editor. Uses `value` (not `initialValue` + ValueKey) so feed updates
/// never reset the widget state mid-interaction.
class _CalendarPicker extends StatelessWidget {
  final PlannerEvent? existing;
  final String? saveTargetFeedId;
  final bool Function(FeedCubit feeds) canChangeCalendar;
  final ValueChanged<String?> onChanged;

  const _CalendarPicker({
    required this.existing,
    required this.saveTargetFeedId,
    required this.canChangeCalendar,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final feedCubit = context.watch<FeedCubit>();
    final existing = this.existing;
    final showPicker =
        existing == null || feedCubit.isEventEditable(existing);
    if (!showPicker) return const SizedBox.shrink();
    final googleFeeds = feedCubit.state
        .where((f) =>
            f.kind == FeedKind.google &&
            f.calendarId != null &&
            f.calendarId!.isNotEmpty)
        .toList();
    final validTarget =
        googleFeeds.any((f) => f.id == saveTargetFeedId)
            ? saveTargetFeedId
            : null;
    final disabled = existing != null &&
        !canChangeCalendar(feedCubit) &&
        feedCubit.isEventEditable(existing);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String?>(
          initialValue: validTarget,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: existing == null ? 'Save to' : 'Calendar',
            border: const OutlineInputBorder(),
            helperText: disabled
                ? 'Moving repeating events between calendars isn’t supported yet.'
                : null,
          ),
          items: [
            const DropdownMenuItem(
              value: null,
              child: Text('This device'),
            ),
            for (final feed in googleFeeds)
              DropdownMenuItem(
                value: feed.id,
                child: Text(feed.name),
              ),
          ],
          onChanged: disabled ? null : onChanged,
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _EventPeopleLine extends StatelessWidget {
  final PlannerEvent event;

  const _EventPeopleLine({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = event.assignees.take(3).toList();
    final extra = event.assignees.length - shown.length;
    final names = shown.map((a) => a.displayName).join(', ');
    return Row(
      children: [
        SizedBox(
          width: shown.length * 18.0 + 4,
          height: 20,
          child: Stack(
            children: [
              for (var i = 0; i < shown.length; i++)
                Positioned(
                  left: i * 18.0,
                  child: CircleAvatar(
                    radius: 10,
                    child: Text(
                      shown[i].displayName.isEmpty
                          ? '?'
                          : shown[i].displayName[0].toUpperCase(),
                      style: const TextStyle(fontSize: 10),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            extra > 0 ? '$names +$extra' : names,
            style: theme.textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _PlaceField extends StatelessWidget {
  final String? value;
  final ValueChanged<String?> onChanged;

  const _PlaceField({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    List<Place> places;
    try {
      places = context.watch<PlacesCubit>().state;
    } catch (_) {
      return const SizedBox.shrink();
    }
    if (places.isEmpty) return const SizedBox.shrink();
    // A stale placeId (place deleted after the event was saved) would crash
    // DropdownButtonFormField because initialValue must match exactly one
    // item. Surface it as an extra item so the edit form still mounts and
    // Delete stays reachable; picking a new place replaces it.
    final hasMatch =
        value == null || places.any((place) => place.id == value);
    return DropdownButtonFormField<String?>(
      initialValue: value,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Saved place (for auto-report)',
        border: OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem(value: null, child: Text('No place')),
        if (!hasMatch)
          DropdownMenuItem(
            value: value,
            child: const Text('Unknown place'),
          ),
        for (final place in places)
          DropdownMenuItem(value: place.id, child: Text(place.name)),
      ],
      onChanged: onChanged,
    );
  }
}

/// Events already on the picked day, so a time can be chosen without
/// flipping back to the calendar behind the sheet. On narrow screens the
/// sheet's scrim dims the calendar ("grayed out"), which is why synced
/// calendars looked missing when scheduling from the task menu.
///
/// Conflict badges are same-granularity only: all-day marks the whole
/// day, a timed event a window on it, so the two never overlap. All-day
/// events conflict with other all-day events; timed events conflict when
/// their intervals intersect.
class _DayConflictsSection extends StatelessWidget {
  final DateTime day;
  final bool allDay;
  final TimeOfDay startTime;
  final TimeOfDay endTime;
  final String? excludeId;

  const _DayConflictsSection({
    required this.day,
    required this.allDay,
    required this.startTime,
    required this.endTime,
    this.excludeId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final selStart = DateTime(
        day.year, day.month, day.day, startTime.hour, startTime.minute);
    var selEnd = DateTime(
        day.year, day.month, day.day, endTime.hour, endTime.minute);
    if (!selEnd.isAfter(selStart)) {
      selEnd = selStart.add(const Duration(hours: 1));
    }
    List<PlannerEvent> dayEvents;
    // Same-granularity conflicts only, keyed by id. An all-day event and a
    // timed event never clash: one marks a whole day, the other a window
    // on it. Both all-day conflict on a shared day; two timed events
    // conflict when their intervals intersect.
    Set<String> conflictingIds;
    String? syncWarning;
    try {
      final calendar = context.watch<CalendarCubit>();
      final feeds = context.watch<FeedCubit>();
      dayEvents = calendar
          .eventsOnDay(day)
          .where((e) =>
              e.id != calendarDraftEventId &&
              e.id != excludeId &&
              feeds.isFeedVisible(e.feedId))
          .toList();
      conflictingIds = <String>{};
      for (final event in dayEvents) {
        if (event.allDay != allDay) continue;
        if (allDay) {
          // Both day-grained and both list for the picked day.
          conflictingIds.add(event.id);
          continue;
        }
        // Compare the occurrence on the picked day, not the series
        // master: a weekly class's master sits weeks in the past, where
        // an interval check against today's window never fires.
        final duration = event.end.isAfter(event.start)
            ? event.end.difference(event.start)
            : const Duration(hours: 1);
        for (final occ in calendar.occurrencesOf(event, dayStart, dayEnd)) {
          if (occ.isBefore(selEnd) && selStart.isBefore(occ.add(duration))) {
            conflictingIds.add(event.id);
            break;
          }
        }
      }
      final failing = feeds.state
          .where((f) =>
              f.enabled &&
              f.kind == FeedKind.google &&
              f.lastError != null &&
              f.lastError!.isNotEmpty)
          .toList();
      if (failing.isNotEmpty) {
        syncWarning = 'Google sync issue (${failing.first.name}): '
            '${failing.first.lastError} — events may be missing.';
      }
    } catch (_) {
      return const SizedBox.shrink();
    }
    dayEvents.sort((a, b) => a.start.compareTo(b.start));

    final timeFormat = DateFormat('h:mm a');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            dayEvents.isEmpty
                ? 'That day — clear'
                : 'That day (${dayEvents.length})',
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 4),
          if (dayEvents.isEmpty)
            Text(
              'No events that day — clear.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            for (final event in dayEvents.take(6))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: _dotColor(context, event),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            event.subject,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                          Text(
                            event.allDay
                                ? 'All day'
                                : '${timeFormat.format(event.start)} – '
                                    '${timeFormat.format(event.end)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (conflictingIds.contains(event.id))
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'Overlaps',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          if (dayEvents.length > 6)
            Text(
              '+${dayEvents.length - 6} more that day',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          if (syncWarning != null) ...[
            const SizedBox(height: 6),
            Text(
              syncWarning,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _dotColor(BuildContext context, PlannerEvent event) {
    final label = event.classLabel;
    if (label != null && label.isNotEmpty) return courseColor(label);
    if (event.colorValue != null) {
      return mutedCalendarColor(Color(event.colorValue!));
    }
    try {
      final feed = context.read<FeedCubit>().byId(event.feedId ?? '');
      if (feed != null) return mutedCalendarColor(feed.color);
    } catch (_) {}
    return const Color(_personalEventColor);
  }
}

class _EventDetailSheet extends StatelessWidget {
  final PlannerEvent event;
  final VoidCallback? onReport;

  const _EventDetailSheet({required this.event, this.onReport});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: BlocBuilder<CalendarCubit, List<PlannerEvent>>(
        builder: (context, events) {
          var current = event;
          for (final e in events) {
            if (e.id == event.id) {
              current = e;
              break;
            }
          }
          final report = onReport;
          return EventDetailView(
            event: current,
            onEdit: () {
              Navigator.of(context).pop();
              showEventEditor(context, existing: current);
            },
            onReport: report == null
                ? null
                : () {
                    Navigator.of(context).pop();
                    Future.microtask(report);
                  },
            onClose: () => Navigator.of(context).pop(),
          );
        },
      ),
    );
  }
}

class EventDetailView extends StatelessWidget {
  final PlannerEvent event;
  final VoidCallback? onEdit;
  final VoidCallback? onReport;
  final VoidCallback? onClose;

  const EventDetailView({
    super.key,
    required this.event,
    this.onEdit,
    this.onReport,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final feedCubit = context.watch<FeedCubit>();
    final feed = feedCubit.byId(event.feedId ?? '');
    final editable =
        onEdit != null && feedCubit.isEventEditable(event);
    final pushesToGoogle =
        event.isFromFeed && feedCubit.isRemoteEditable(event);
    final classLabel = event.classLabel;
    final Color dotColor = classLabel != null && classLabel.isNotEmpty
        ? courseColor(classLabel)
        : (feed == null
            ? const Color(_personalEventColor)
            : mutedCalendarColor(feed.color));
    final String sourceLabel =
        classLabel != null && classLabel.isNotEmpty
            ? classLabel
            : (feed?.name ?? 'Event');
    final formatter = DateFormat('EEE, MMM d, yyyy');
    final timeFormatter = DateFormat('h:mm a');
    final String when;
    if (event.allDay) {
      when = 'All day · ${formatter.format(event.start)}';
    } else if (event.end.isAfter(event.start)) {
      when =
          '${timeFormatter.format(event.start)} – ${timeFormatter.format(event.endOfDay)} · ${formatter.format(event.start)}';
    } else {
      when =
          '${timeFormatter.format(event.start)} · ${formatter.format(event.start)}';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sourceLabel,
                  style: theme.textTheme.labelMedium,
                ),
              ),
              if (event.recurrenceRule.isNotEmpty)
                const Icon(Icons.repeat, size: 16),
              if (event.isTask) ...[
                const SizedBox(width: 4),
                Icon(
                  event.failed
                      ? Icons.cancel
                      : event.done
                          ? Icons.check_circle
                          : Icons.check_circle_outline,
                  size: 16,
                  color: event.failed
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            event.subject,
            style: theme.textTheme.titleLarge?.copyWith(
              decoration:
                  (event.isTask && event.done) || event.failed ? TextDecoration.lineThrough : null,
              color: event.failed ? theme.colorScheme.error : null,
            ),
          ),
          const SizedBox(height: 4),
          Text(when, style: theme.textTheme.bodyMedium),
          if (event.hasReminder) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.notifications_outlined, size: 16),
                const SizedBox(width: 4),
                Text(
                  'Reminder: ${eventReminderLabel(event.reminderMinutesBefore!)}',
                ),
              ],
            ),
          ],
          if (event.location != null && event.location!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Where: ${event.location}'),
          ],
          if (event.notes != null && event.notes!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(event.notes!),
          ],
          if (event.assignees.isNotEmpty) ...[
            const SizedBox(height: 8),
            _EventPeopleLine(event: event),
          ],
          if (event.isTask) ...[
            const SizedBox(height: 8),
            _TaskStatusTile(event: event),
            const SizedBox(height: 8),
            TaskTimeSection(event: event),
            const SizedBox(height: 8),
            _GoalAssignmentSection(event: event),
          ] else if (!event.allDay) ...[
            // Plain calendar events (Google / personal) can also be timed
            // like in Toggl: one tap on Start records from now, Stop saves
            // the reported interval shown in the Plan + Report view.
            const SizedBox(height: 8),
            TimeReportSection(event: event),
          ],
          const SizedBox(height: 8),
          if (event.isFromFeed)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                pushesToGoogle
                    ? event.isRecurringInstance
                        ? 'Part of a repeating series on ${feed?.name ?? 'Google'} — '
                            'dragging moves just this occurrence, editing '
                            'lets you pick this occurrence or the whole series.'
                        : 'Synced with ${feed?.name ?? 'Google'} — edits save '
                            'back to Google Calendar.'
                    : 'Synced from ${feed?.name ?? 'your class'} — changes there '
                        'will overwrite local edits on the next sync.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (onReport != null && event.isTask)
                TextButton(
                  onPressed: onReport,
                  child: const Text('Report'),
                ),
              if (editable)
                TextButton(
                  onPressed: onEdit,
                  child: const Text('Edit'),
                ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: onClose,
                child: const Text('Close'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TaskStatusTile extends StatelessWidget {
  final PlannerEvent event;

  const _TaskStatusTile({required this.event});

  @override
  Widget build(BuildContext context) {
    Node? backing;
    try {
      for (final n in context.watch<NodeCubit>().state) {
        if (n.calendarEventId == event.id ||
            n.sourceEventId == event.id ||
            n.id == event.taskId) {
          backing = n;
          break;
        }
      }
    } catch (_) {}
    final done = backing?.isDone ?? event.done;
    final failed =
        backing != null ? backing.status == NodeStatus.failed : event.failed;
    final label = done
        ? 'Completed'
        : failed
            ? 'Failed'
            : 'Not done';
    return Row(
      children: [
        EventNodeCheckbox(event: event),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: failed
                      ? Theme.of(context).colorScheme.error
                      : null,
                  fontWeight:
                      done || failed ? FontWeight.w600 : null,
                ),
          ),
        ),
      ],
    );
  }
}

/// Goal assignment for a task-event: which goal(s) its backing node
/// reports to, plus assign/remove. Backing nodes parented under a goal
/// roll their completion into the goal's progress.
class _GoalAssignmentSection extends StatelessWidget {
  final PlannerEvent event;

  const _GoalAssignmentSection({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    List<Node> all = const [];
    try {
      all = context.watch<NodeCubit>().state;
    } catch (_) {}
    Node? backing;
    for (final n in all) {
      if (n.calendarEventId == event.id ||
          n.sourceEventId == event.id ||
          n.id == event.taskId) {
        backing = n;
        break;
      }
    }
    final byId = {for (final n in all) n.id: n};
    final parents = backing == null
        ? const <Node>[]
        : [
            for (final pid in backing.parentIds)
              if (byId[pid] != null) byId[pid]!,
          ];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Goal', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          if (backing == null) ...[
            Text(
              'This task has no linked step yet — assign to create the link.',
              style: theme.textTheme.bodySmall,
            ),
          ] else if (parents.isEmpty) ...[
            Text(
              'Not assigned to a goal yet.',
              style: theme.textTheme.bodySmall,
            ),
          ] else ...[
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final p in parents)
                  Chip(
                    label: Text(
                      p.title,
                      overflow: TextOverflow.ellipsis,
                    ),
                    deleteIcon: const Icon(Icons.close, size: 16),
                    onDeleted: () => _unassign(context, p.id),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => _assign(context),
              icon: const Icon(Icons.flag_outlined, size: 16),
              label: Text(parents.isEmpty ? 'Assign to goal' : 'Change goal'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _assign(BuildContext context) async {
    NodeCubit nodes;
    CalendarCubit calendar;
    try {
      nodes = context.read<NodeCubit>();
      calendar = context.read<CalendarCubit>();
    } catch (_) {
      return;
    }
    final live = calendar.byId(event.id) ?? event;
    final liveBacking =
        NodeEventLink.backingNodeFor(nodes, calendar, event.id);
    final goal = await showGoalPicker(
      context,
      excludeNodeId: liveBacking?.id,
    );
    if (goal == null || !context.mounted) return;
    // Repeating events offer a scope choice: just this occurrence, or
    // this plus all future instances (the seed is always included so an
    // explicitly picked past occurrence still acts on itself).
    var includeSeries = false;
    if (NodeEventLink.isRepeatingEvent(live)) {
      final futureMembers =
          NodeEventLink.futureSeriesMembers(calendar, live);
      if (futureMembers.length > 1) {
        final scope = await showDialog<_GoalAssignScope>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Assign repeating event'),
            content: Text(
              'Apply “${goal.title}” to just this occurrence, or to '
              'this and all future instances (${futureMembers.length})?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext)
                    .pop(_GoalAssignScope.cancel),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext)
                    .pop(_GoalAssignScope.occurrence),
                child: const Text('This occurrence'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext)
                    .pop(_GoalAssignScope.series),
                child: Text('This + future (${futureMembers.length})'),
              ),
            ],
          ),
        );
        if (scope == null || scope == _GoalAssignScope.cancel) return;
        includeSeries = scope == _GoalAssignScope.series;
        if (!context.mounted) return;
      }
    }
    final result = NodeEventLink.assignEventToGoal(
      calendar,
      nodes,
      event.id,
      goal.id,
      includeSeries: includeSeries,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.assigned > 1
              ? 'Assigned ${result.assigned} items to “${goal.title}”'
              : result.assigned == 1
                  ? 'Assigned to “${goal.title}”'
                  : (result.error ?? 'Already assigned to “${goal.title}”.'),
        ),
      ),
    );
  }

  Future<void> _unassign(BuildContext context, String goalId) async {
    NodeCubit nodes;
    CalendarCubit calendar;
    try {
      nodes = context.read<NodeCubit>();
      calendar = context.read<CalendarCubit>();
    } catch (_) {
      return;
    }
    final live = calendar.byId(event.id) ?? event;
    // When several future occurrences share this goal, offer to remove
    // just this one or this plus all future instances.
    var includeSeries = false;
    if (NodeEventLink.isRepeatingEvent(live)) {
      final futureMembers =
          NodeEventLink.futureSeriesMembers(calendar, live);
      if (futureMembers.length > 1) {
        var assignedCount = 0;
        for (final m in futureMembers) {
          final backing =
              NodeEventLink.backingNodeFor(nodes, calendar, m.id);
          if (backing?.parentIds.contains(goalId) ?? false) {
            assignedCount++;
          }
        }
        if (assignedCount > 1) {
          final scope = await showDialog<_GoalAssignScope>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('Remove from goal'),
              content: Text(
                'Remove just this occurrence, or this and all future '
                'instances ($assignedCount assigned)?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext)
                      .pop(_GoalAssignScope.cancel),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext)
                      .pop(_GoalAssignScope.occurrence),
                  child: const Text('This occurrence'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext)
                      .pop(_GoalAssignScope.series),
                  child: const Text('This + future'),
                ),
              ],
            ),
          );
          if (scope == null || scope == _GoalAssignScope.cancel) return;
          includeSeries = scope == _GoalAssignScope.series;
          if (!context.mounted) return;
        }
      }
    }
    if (includeSeries) {
      final result = NodeEventLink.unassignEventFromGoal(
        calendar,
        nodes,
        event.id,
        goalId,
        includeSeries: true,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.removed > 1
                ? 'Removed ${result.removed} items from goal'
                : result.removed == 1
                    ? 'Removed from goal'
                    : (result.error ?? 'Already removed from goal'),
          ),
        ),
      );
      return;
    }
    final backing = NodeEventLink.backingNodeFor(nodes, calendar, event.id);
    if (backing == null) return;
    final error =
        NodeEventLink.unassignNodeFromGoal(nodes, backing.id, goalId);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ?? 'Removed from goal'),
      ),
    );
  }
}

enum _GoalAssignScope { cancel, occurrence, series }
