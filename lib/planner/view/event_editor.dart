import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../common/undo/undo_cubit.dart';
import '../../reporting/bloc/places_cubit.dart';
import '../../reporting/model/place.dart';
import '../bloc/calendar_cubit.dart';
import '../bloc/calendar_draft_cubit.dart';
import '../bloc/feed_cubit.dart';
import '../bloc/settings_cubit.dart';
import '../bloc/task_cubit.dart';
import '../model/event_reschedule.dart';
import '../model/feed.dart';
import '../model/planner_event.dart';
import '../model/recurrence.dart';
import '../model/task.dart';
import '../model/task_assignee.dart';
import '../service/task_event_link.dart';
import 'people_field.dart';
import 'task_checkbox.dart';
import 'task_finish_sheet.dart';

const int _personalEventColor = 0xFF6B8F8A;

Future<void> showEventEditor(
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
  return showModalBottomSheet<void>(
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
            onFinished: () => Navigator.of(context).pop(),
            onCancelled: () => Navigator.of(context).pop(),
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
  PlannerEvent? _seriesMaster;
  bool _loadingMaster = false;
  bool _masterFailed = false;

  bool get _editingSeries => _seriesMaster != null;

  @override
  void initState() {
    super.initState();
    _subject = TextEditingController();
    _notes = TextEditingController();
    _location = TextEditingController();
    _sourceTaskId = widget.existing?.taskId ?? widget.initialTaskId;
    final defaultFeedId =
        context.read<SettingsCubit>().state.defaultEventFeedId;
    if (widget.existing == null &&
        defaultFeedId != null &&
        defaultFeedId.isNotEmpty) {
      final feed = context.read<FeedCubit>().byId(defaultFeedId);
      if (feed != null &&
          feed.kind == FeedKind.google &&
          feed.calendarId != null &&
          feed.calendarId!.isNotEmpty) {
        _saveTargetFeedId = defaultFeedId;
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
    if (widget.existing == null && widget.onDraftChanged != null) {
      _subject.addListener(_emitDraft);
      _notes.addListener(_emitDraft);
      _location.addListener(_emitDraft);
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
        _customRepeat = true;
      } else {
        _seriesMaster = master;
        _applyEvent(master);
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
      // Creating a calendar block for a task: start from the task's people
      // so saving back can't silently drop them.
      try {
        final task = context.read<TaskCubit>().byId(_sourceTaskId!);
        if (task != null && task.assignees.isNotEmpty) {
          _people = List.of(task.assignees);
        }
      } catch (_) {}
    }
    _isTask = existing?.isTask ?? false;
    _done = existing?.done ?? false;
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
    _subject.dispose();
    _notes.dispose();
    _location.dispose();
    super.dispose();
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
    if (onDraftChanged == null || widget.existing != null) return;
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
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loadingMaster) {
      return const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    final googleFeeds = context
        .watch<FeedCubit>()
        .state
        .where((f) =>
            f.kind == FeedKind.google &&
            f.calendarId != null &&
            f.calendarId!.isNotEmpty)
        .toList();
    final validTarget =
        googleFeeds.any((f) => f.id == _saveTargetFeedId)
            ? _saveTargetFeedId
            : null;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        controller: widget.scrollController,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.title != null) ...[
              Text(widget.title!, style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
            ],
            if (_editingSeries)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'You’re editing the whole series — changes apply to '
                  'every occurrence.',
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
            if (widget.existing == null) ...[
              DropdownButtonFormField<String?>(
                key: ValueKey('save-to:$validTarget'),
                initialValue: validTarget,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Save to',
                  border: OutlineInputBorder(),
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
                onChanged: (value) =>
                    setState(() => _saveTargetFeedId = value),
              ),
              const SizedBox(height: 12),
            ],
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
                  child: _dateField(theme),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('All day'),
                    value: _allDay,
                    onChanged: (value) {
                      setState(() => _allDay = value);
                      _emitDraft();
                    },
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
            _repeatSection(theme),
            const SizedBox(height: 12),
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
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (widget.existing != null && widget.allowDelete) ...[
                  TextButton(
                    onPressed: _saving ? null : () => _delete(context),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    child: const Text('Delete'),
                  ),
                  const Spacer(),
                ],
                TextButton(
                  onPressed:
                      _saving ? null : () => widget.onCancelled?.call(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : () => _save(context),
                  child: Text(
                    _saving
                        ? 'Saving…'
                        : (widget.existing == null ? 'Add' : 'Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
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
            setState(() => _repeatKind = value ?? RepeatKind.none);
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
                    });
                    _emitDraft();
                  },
                ),
            ],
          ),
        ],
        if (_repeatKind != RepeatKind.none) ...[
          const SizedBox(height: 8),
          SegmentedButton<RepeatEndKind>(
            segments: const [
              ButtonSegment(value: RepeatEndKind.never, label: Text('Forever')),
              ButtonSegment(value: RepeatEndKind.after, label: Text('N times')),
              ButtonSegment(value: RepeatEndKind.until, label: Text('Until')),
            ],
            selected: {_endKind},
            onSelectionChanged: (selection) {
              setState(() => _endKind = selection.first);
              _emitDraft();
            },
          ),
          if (_endKind == RepeatEndKind.after)
            Row(
              children: [
                const Text('Repeats'),
                const SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  child: TextFormField(
                    initialValue: _count > 0 ? '$_count' : '',
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(hintText: '10'),
                    onChanged: (value) {
                      setState(() => _count = int.tryParse(value) ?? 0);
                      _emitDraft();
                    },
                  ),
                ),
                const Text('times'),
              ],
            ),
          if (_endKind == RepeatEndKind.until)
            Row(
              children: [
                Text(
                  _until == null
                      ? 'Until date not set'
                      : DateFormat('EEE, MMM d, yyyy').format(_until!),
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
                      setState(() => _until = picked);
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
    final editTarget = _seriesMaster ?? widget.existing;
    final config = RepeatConfig(
      kind: _repeatKind,
      weekDays: _weekDays,
      endKind: _endKind,
      count: _count,
      until: _until,
    );
    final rule = _customRepeat
        ? (editTarget?.recurrenceRule ?? config.ruleFor(start))
        : config.ruleFor(start);
    final notes =
        _notes.text.trim().isEmpty ? null : _notes.text.trim();
    final location =
        _location.text.trim().isEmpty ? null : _location.text.trim();
    final done = _isTask && _done;
    if (widget.existing == null) {
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
              context.read<TaskCubit>().setCalendarEvent(
                    _sourceTaskId!,
                    createdId,
                  );
            } catch (_) {}
          }
        }
        _applyLocalAssignees(result.created?.id ?? draft.id);
        _mirrorAssigneesToSourceTask();
        _applyTaskLinkPostSync(result.created?.id ?? draft.id);
        widget.onFinished?.call();
        return;
      }
      calendarCubit.addEvent(draft);
      if (_sourceTaskId != null) {
        try {
          context
              .read<TaskCubit>()
              .setCalendarEvent(_sourceTaskId!, draft.id);
        } catch (_) {}
      }
      _syncTaskLink(draft);
      widget.onFinished?.call();
      return;
    }
    final base = editTarget!;
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
    );
    if (_editingSeries) {
      setState(() => _saving = true);
      final error =
          await feedCubit.pushEventUpdate(updated, series: true);
      if (!mounted) return;
      setState(() => _saving = false);
      if (error != null) {
        messenger.showSnackBar(
          SnackBar(content: Text(error)),
        );
        return;
      }
      _applyLocalAssignees(updated.id);
      _applyTaskLinkPostSync(updated.id);
      widget.onFinished?.call();
      return;
    }
    if (feedCubit.isRemoteEditable(base)) {
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
      _applyTaskLinkPostSync(updated.id);
      widget.onFinished?.call();
      return;
    }
    calendarCubit.updateEvent(updated);
    _syncTaskLink(updated);
    widget.onFinished?.call();
  }

  /// Mirrors a locally saved event's task flag into [TaskCubit]: creates or
  /// refreshes the backing task when marked, removes backing tasks when
  /// un-marked.
  void _syncTaskLink(PlannerEvent saved) {
    TaskCubit tasks;
    try {
      tasks = context.read<TaskCubit>();
    } catch (_) {
      return;
    }
    final calendar = context.read<CalendarCubit>();
    if (!saved.isTask) {
      tasks.removeTasksForEvent(saved.id);
      return;
    }
    if (saved.isFromFeed) {
      tasks.ensureShadowForFeedEvent(saved);
      tasks.setDoneForEvent(
        saved.id,
        done: saved.done,
        completedAt: saved.completedAt,
      );
      return;
    }
    final taskId = tasks.upsertLinkedTaskForEvent(saved);
    calendar.setTaskLink(saved.id, taskId);
    tasks.setDoneForEvent(
      saved.id,
      done: saved.done,
      completedAt: saved.completedAt,
    );
  }

  /// Re-applies the editor's task flag after a Google push + re-sync, which
  /// otherwise drops the local-only [PlannerEvent.isTask] state.
  void _applyTaskLinkPostSync(String syncedId) {
    if (!_isTask) return;
    TaskCubit tasks;
    try {
      tasks = context.read<TaskCubit>();
    } catch (_) {
      return;
    }
    final calendar = context.read<CalendarCubit>();
    TaskEventLink.markEventAsTask(calendar, tasks, syncedId);
    if (_done) {
      TaskEventLink.toggleEventDone(calendar, tasks, syncedId);
    }
  }

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

  /// Mirrors the editor's people onto the source task a new event was
  /// created from. Skipped when nothing changed (the common case: the
  /// picker was seeded from the task).
  void _mirrorAssigneesToSourceTask() {
    final sourceId = _sourceTaskId;
    if (sourceId == null) return;
    TaskCubit tasks;
    try {
      tasks = context.read<TaskCubit>();
    } catch (_) {
      return;
    }
    final source = tasks.byId(sourceId);
    if (source == null) return;
    if (_sameAssignees(source.assignees, _people)) return;
    tasks.updateTask(source.copyWith(assignees: List.of(_people)));
  }

  void _delete(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final feedCubit = context.read<FeedCubit>();
    final calendarCubit = context.read<CalendarCubit>();
    final existing = widget.existing;
    if (existing == null) return;
    void clearTaskLink() {
      try {
        final taskCubit = context.read<TaskCubit>();
        if (existing.taskId != null) {
          taskCubit.clearCalendarEvent(existing.taskId!);
        }
        taskCubit.clearCalendarEventForEvent(existing.id);
        taskCubit.removeTasksForEvent(existing.id);
      } catch (_) {}
    }

    if (!feedCubit.isRemoteEditable(existing)) {
      calendarCubit.deleteEvent(existing.id);
      clearTaskLink();
      messenger.showSnackBar(
        SnackBar(
          content: const Text('Event deleted'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => context.read<UndoCubit>().undo(),
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
    clearTaskLink();
    widget.onFinished?.call();
  }
}

enum _DeleteChoice { cancel, occurrence, series }

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
    return DropdownButtonFormField<String?>(
      initialValue: value,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Saved place (for auto-report)',
        border: OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem(value: null, child: Text('No place')),
        for (final place in places)
          DropdownMenuItem(value: place.id, child: Text(place.name)),
      ],
      onChanged: onChanged,
    );
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
            _TaskTimeSection(event: event),
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
                            'changes the whole series.'
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
    Task? backing;
    try {
      for (final t in context.watch<TaskCubit>().state) {
        if (t.calendarEventId == event.id ||
            t.sourceEventId == event.id ||
            t.id == event.taskId) {
          backing = t;
          break;
        }
      }
    } catch (_) {}
    final done = backing?.done ?? event.done;
    final failed = backing?.failed ?? event.failed;
    final label = done
        ? 'Completed'
        : failed
            ? 'Failed'
            : 'Not done';
    return Row(
      children: [
        EventTaskCheckbox(event: event),
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

class _TaskTimeSection extends StatelessWidget {
  final PlannerEvent event;

  const _TaskTimeSection({required this.event});

  @override
  Widget build(BuildContext context) {
    Task? task;
    try {
      for (final t in context.watch<TaskCubit>().state) {
        if (t.calendarEventId == event.id ||
            t.sourceEventId == event.id ||
            t.id == event.taskId) {
          task = t;
          break;
        }
      }
    } catch (_) {}
    if (task == null) {
      if (event.allDay) return const SizedBox.shrink();
      return _TimeReportSection(event: event);
    }
    final theme = Theme.of(context);
    final timeFormatter = DateFormat('h:mm a');
    final plannedStart = task.plannedStart ?? event.start;
    final plannedEnd = task.plannedEnd ?? event.end;
    final plannedMin = plannedEnd.isAfter(plannedStart)
        ? plannedEnd.difference(plannedStart).inMinutes
        : 0;
    final reported = task.reportedDuration;
    final lines = <String>[
      'Planned ${timeFormatter.format(plannedStart)} – '
          '${timeFormatter.format(plannedEnd)} (${plannedMin}m)',
      if (task.isTracking && task.timerStartedAt != null)
        'Recording since ${timeFormatter.format(task.timerStartedAt!)}',
      if (reported != null &&
          task.actualStart != null &&
          task.actualEnd != null)
        'Reported ${timeFormatter.format(task.actualStart!)} – '
            '${timeFormatter.format(task.actualEnd!)} (${reported.inMinutes}m)',
      if (task.failed) 'Marked as failed',
    ];
    final taskId = task.id;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Time tracking', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          for (final line in lines)
            Text(
              line,
              style: theme.textTheme.bodySmall?.copyWith(
                color: line.startsWith('Marked as failed')
                    ? theme.colorScheme.error
                    : null,
                fontWeight: line.startsWith('Recording') ||
                        line.startsWith('Marked as failed')
                    ? FontWeight.w600
                    : null,
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (task.isTracking)
                FilledButton.icon(
                  onPressed: () => stopTaskAndFinish(context, taskId),
                  icon: const Icon(Icons.stop, size: 16),
                  label: const Text('Stop'),
                )
              else
                OutlinedButton.icon(
                  onPressed: task.done
                      ? null
                      : () {
                          try {
                            context
                                .read<TaskCubit>()
                                .startTracking(taskId);
                          } catch (_) {}
                        },
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('Start'),
                ),
              OutlinedButton(
                onPressed: () {
                  try {
                    TaskEventLink.setTaskFailed(
                      context.read<TaskCubit>(),
                      context.read<CalendarCubit>(),
                      taskId,
                      !task!.failed,
                    );
                  } catch (_) {}
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor:
                      task.failed ? null : theme.colorScheme.error,
                ),
                child: Text(task.failed ? 'Unfail' : 'Mark failed'),
              ),
              TextButton(
                onPressed: () =>
                    showFollowUpScheduler(context, taskId: taskId),
                child: const Text('Follow-up'),
              ),
              if (task.hasReported && !task.isTracking)
                TextButton(
                  onPressed: () {
                    try {
                      context.read<TaskCubit>().clearReported(taskId);
                    } catch (_) {}
                  },
                  child: const Text('Clear reported'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TimeReportSection extends StatelessWidget {
  final PlannerEvent event;

  const _TimeReportSection({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeFormatter = DateFormat('h:mm a');
    final plannedMin = event.plannedDuration.inMinutes;
    final reported = event.reportedDuration;
    final lines = <String>[
      'Planned ${timeFormatter.format(event.start)} – '
          '${timeFormatter.format(event.end)} (${plannedMin}m)',
      if (event.isTracking && event.timerStartedAt != null)
        'Recording since ${timeFormatter.format(event.timerStartedAt!)}',
      if (reported != null &&
          event.actualStart != null &&
          event.actualEnd != null)
        'Reported ${timeFormatter.format(event.actualStart!)} – '
            '${timeFormatter.format(event.actualEnd!)} (${reported.inMinutes}m)',
      if (event.failed) 'Marked as failed',
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
          Text('Time tracking', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          for (final line in lines)
            Text(
              line,
              style: theme.textTheme.bodySmall?.copyWith(
                color: line.startsWith('Marked as failed')
                    ? theme.colorScheme.error
                    : null,
                fontWeight: line.startsWith('Recording') ||
                        line.startsWith('Marked as failed')
                    ? FontWeight.w600
                    : null,
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (event.isTracking)
                FilledButton.icon(
                  onPressed: () => context
                      .read<CalendarCubit>()
                      .stopTracking(event.id),
                  icon: const Icon(Icons.stop, size: 16),
                  label: const Text('Stop'),
                )
              else
                OutlinedButton.icon(
                  onPressed: () => context
                      .read<CalendarCubit>()
                      .startTracking(event.id),
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('Start'),
                ),
              OutlinedButton(
                onPressed: () => context
                    .read<CalendarCubit>()
                    .setFailed(event.id, !event.failed),
                style: OutlinedButton.styleFrom(
                  foregroundColor: event.failed
                      ? null
                      : theme.colorScheme.error,
                ),
                child: Text(event.failed ? 'Unfail' : 'Mark failed'),
              ),
              if (event.hasReported && !event.isTracking)
                TextButton(
                  onPressed: () => context
                      .read<CalendarCubit>()
                      .clearReported(event.id),
                  child: const Text('Clear reported'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
