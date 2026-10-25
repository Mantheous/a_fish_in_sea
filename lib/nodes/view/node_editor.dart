import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'package:a_fish_in_sea/anki/anki_connect.dart';
import 'package:a_fish_in_sea/anki/anki_server.dart';
import 'package:a_fish_in_sea/anki/anki_import.dart';
import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/service/node_transaction_cleanup.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_editor_schedule.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/nodes/view/class_picker.dart';
import 'package:a_fish_in_sea/nodes/view/metrics_fields.dart';
import 'package:a_fish_in_sea/nodes/view/parents_field.dart';
import 'package:a_fish_in_sea/nodes/view/timer_edit_sheet.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/planner/model/task_assignee.dart';
import 'package:a_fish_in_sea/planner/view/class_names.dart';
import 'package:a_fish_in_sea/planner/view/people_field.dart';

/// Shows the node editor dialog. Returns the created or updated node on
/// save, or null when the dialog is cancelled or the node is deleted.
/// Callers that ignore the result keep working unchanged.
Future<Node?> showNodeEditor(
  BuildContext context, {
  Node? existing,
  bool enableMoney = false,
  bool enableRecurrence = false,

  /// Pre-selected parents for a brand-new node (e.g. "add subgoal" from a
  /// goal tile). Ignored when [existing] is set.
  List<String> initialParentIds = const [],
}) {
  return showDialog<Node?>(
    context: context,
    builder: (dialogContext) => _NodeEditorDialog(
      existing: existing,
      enableMoney: enableMoney,
      enableRecurrence: enableRecurrence,
      initialParentIds: initialParentIds,
    ),
  );
}

class _NodeEditorDialog extends StatefulWidget {
  final Node? existing;
  final bool enableMoney;
  final bool enableRecurrence;
  final List<String> initialParentIds;

  const _NodeEditorDialog({
    this.existing,
    this.enableMoney = false,
    this.enableRecurrence = false,
    this.initialParentIds = const [],
  });

  @override
  State<_NodeEditorDialog> createState() => _NodeEditorDialogState();
}

class _NodeEditorDialogState extends State<_NodeEditorDialog> {
  late final TextEditingController _title;
  late final TextEditingController _notes;
  late List<String> _parents;

  bool _isUnbounded = false;
  bool _isFavorite = false;

  DateTime? _due;
  bool _dateFixed = false;

  bool _hasMoney = false;
  late final TextEditingController _amount;
  MoneyDirection _direction = MoneyDirection.spend;
  TimeScale? _period;
  late final TextEditingController _customDaysCtrl;
  bool _moneyRecurring = false;
  bool _autoRollover = false;
  bool _moneyFixed = false;

  bool _hasEffort = false;
  late final TextEditingController _minutes;
  bool _effortFixed = false;

  bool _hasAnki = false;
  late final TextEditingController _deck;
  late final TextEditingController _targetReviews;
  TimeScale? _ankiPeriod;
  late final TextEditingController _ankiCustomDays;
  late final TextEditingController _manualReviews;
  DateTime? _ankiSyncedAt;
  bool _ankiSyncing = false;

  bool _hasRecurrence = false;
  TimeScale _frequency = TimeScale.daily;
  DateTime? _recurEnd;

  List<AutoFacet> _metrics = const [];
  String? _classNodeId;

  NodeRuleKind _ruleKind = NodeRuleKind.none;
  late final TextEditingController _horizon;
  late final TextEditingController _minBalance;

  late List<TaskAssignee> _people;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: e?.title ?? '');
    _notes = TextEditingController(text: e?.notes ?? '');
    _parents = List.of(e?.parentIds ?? widget.initialParentIds);
    _isUnbounded = e?.isUnbounded ?? false;
    _isFavorite = e?.isFavorite ?? false;
    _due = e?.schedule?.due;
    _dateFixed = e?.schedule?.isFixed ?? false;
    _hasMoney = e?.money != null || widget.enableMoney;
    _amount = TextEditingController(
      text: e?.money != null ? e!.money!.targetAmount.toStringAsFixed(2) : '',
    );
    _direction = e?.money?.direction ?? MoneyDirection.spend;
    _period =
        e?.money?.period ??
        (e == null && widget.enableMoney ? TimeScale.monthly : null);
    _customDaysCtrl = TextEditingController(
      text: e?.money?.customPeriodDays?.toString() ?? '90',
    );
    _moneyRecurring = e?.money?.isRecurring ?? false;
    _autoRollover = e?.money?.autoRollover ?? false;
    _moneyFixed = e?.money?.isFixed ?? false;
    _hasEffort = e?.effort != null;
    _minutes = TextEditingController(
      text: e?.effort != null ? e!.effort!.targetMinutes.toString() : '',
    );
    _effortFixed = e?.effort?.isFixed ?? false;
    _hasAnki = e?.anki != null;
    _deck = TextEditingController(text: e?.anki?.deckName ?? '');
    _targetReviews = TextEditingController(
      text: e?.anki != null ? e!.anki!.targetReviews.toString() : '',
    );
    _ankiPeriod = e?.anki?.period;
    _ankiCustomDays = TextEditingController(
      text: e?.anki?.customPeriodDays?.toString() ?? '30',
    );
    _manualReviews = TextEditingController(
      text: e?.anki?.reviewsActual != null
          ? e!.anki!.reviewsActual.toString()
          : '',
    );
    _ankiSyncedAt = e?.anki?.lastSyncedAt;
    _hasRecurrence = e?.recurrence != null || widget.enableRecurrence;
    _frequency = e?.recurrence?.frequency ?? TimeScale.daily;
    _recurEnd = e?.recurrence?.endDate;
    _metrics = List.of(e?.metrics ?? const []);
    _classNodeId = e?.classNodeId;
    _ruleKind = e?.rule?.kind ?? NodeRuleKind.none;
    _horizon = TextEditingController(
      text: (e?.rule?.horizonDays ?? 3).toString(),
    );
    _minBalance = TextEditingController(
      text: (e?.rule?.minBalance ?? 0).toStringAsFixed(2),
    );
    _people = List.of(e?.assignees ?? const []);
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _amount.dispose();
    _customDaysCtrl.dispose();
    _minutes.dispose();
    _deck.dispose();
    _targetReviews.dispose();
    _ankiCustomDays.dispose();
    _manualReviews.dispose();
    _horizon.dispose();
    _minBalance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.existing;
    return AlertDialog(
      title: Text(e == null ? 'New node' : 'Edit node'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _title,
              autofocus: e == null,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              decoration: const InputDecoration(
                labelText: 'Notes',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            ParentsField(
              selected: _parents,
              excludeId: e?.id,
              onChanged: (next) => setState(() => _parents = next),
            ),
            const SizedBox(height: 12),
            PeopleField(
              selected: _people,
              onChanged: (next) => setState(() => _people = next),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Abstract / unbounded goal'),
              subtitle: const Text(
                'Ongoing direction — no due date, no progress bar. '
                'Track it through concrete subgoals.',
              ),
              value: _isUnbounded,
              onChanged: (v) => setState(() => _isUnbounded = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Favorite goal'),
              subtitle: const Text(
                'Starred goals show on Home and under Favorites.',
              ),
              value: _isFavorite,
              onChanged: (v) => setState(() => _isFavorite = v),
            ),
            if (e?.isClassNode != true) ...[
              const SizedBox(height: 4),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.school_outlined),
                title: const Text('Class'),
                subtitle: Text(_className(context)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_classNodeId != null)
                      IconButton(
                        tooltip: 'Clear class',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() {
                          _classNodeId = null;
                          _parents = [
                            for (final id in _parents)
                              if (context.read<NodeCubit>().byId(id)
                                      ?.isClassNode !=
                                  true)
                                id,
                          ];
                        }),
                      ),
                    IconButton(
                      tooltip: 'Pick class',
                      icon: const Icon(Icons.arrow_drop_down),
                      onPressed: _pickClass,
                    ),
                  ],
                ),
              ),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Class node — its work is the subtree plus imported '
                  'assignments from its bound feeds.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            if (!_isUnbounded) ...[
              const SizedBox(height: 16),
              _sectionTitle(context, 'Schedule'),
              _DateRow(
                label: _due == null
                    ? 'No due date'
                    : 'Due ${MaterialLocalizations.of(context).formatFullDate(_due!)}${_dateFixed ? ' · fixed' : ''}',
                onPick: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _due ?? DateTime.now(),
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) setState(() => _due = picked);
                },
                onClear: _due == null
                    ? null
                    : () => setState(() => _due = null),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Fixed date'),
                subtitle: const Text('Commitment; estimates stay flexible'),
                value: _dateFixed,
                onChanged: (v) => setState(() => _dateFixed = v),
              ),
              // Times are calendar events picked visually on the calendar:
              // save, then use Schedule → Time to place this there. A
              // stored block is preserved on save.
              if ((widget.existing?.schedule?.hasCalendarBlock ?? false))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Has a calendar time — change it via Schedule → Time.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 8),
              _sectionTitle(context, 'Metrics'),
              MetricsFields(
                value: _metrics,
                onChanged: (value) => setState(() => _metrics = value),
                classOptions: _classOptions(context),
                className: classNameResolver(context),
                moneyCategoryOptions: _moneyCategoryOptions(context),
                hasChildren: _hasChildren(context),
              ),
              if (_metrics.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Metrics measure this goal; manual targets below are '
                    'hidden.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (_metrics.isEmpty) ...[
              const SizedBox(height: 8),
              _sectionTitle(context, 'Money'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Tracks money'),
                value: _hasMoney,
                onChanged: (v) => setState(() => _hasMoney = v),
              ),
              if (_hasMoney) ...[
                TextField(
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Target amount',
                    prefixText: '\$ ',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<MoneyDirection>(
                  initialValue: _direction,
                  decoration: const InputDecoration(labelText: 'Direction'),
                  items: const [
                    DropdownMenuItem(
                      value: MoneyDirection.spend,
                      child: Text('Spend (cap)'),
                    ),
                    DropdownMenuItem(
                      value: MoneyDirection.income,
                      child: Text('Income'),
                    ),
                    DropdownMenuItem(
                      value: MoneyDirection.save,
                      child: Text('Save toward'),
                    ),
                  ],
                  onChanged: (v) =>
                      setState(() => _direction = v ?? _direction),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<TimeScale?>(
                  initialValue: _period,
                  decoration: const InputDecoration(
                    labelText: 'Period (optional)',
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('One-time'),
                    ),
                    for (final s in TimeScale.values)
                      DropdownMenuItem(value: s, child: Text(s.displayName)),
                  ],
                  onChanged: (v) => setState(() => _period = v),
                ),
                if (_period == TimeScale.custom) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _customDaysCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Custom period (days)',
                    ),
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Recurring'),
                  value: _moneyRecurring,
                  onChanged: (v) => setState(() => _moneyRecurring = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Auto rollover'),
                  value: _autoRollover,
                  onChanged: _moneyRecurring
                      ? (v) => setState(() => _autoRollover = v)
                      : null,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Fixed amount'),
                  value: _moneyFixed,
                  onChanged: (v) => setState(() => _moneyFixed = v),
                ),
                if (e?.money != null &&
                    e!.money!.linkedTransactionIds.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Reported by ${e.money!.linkedTransactionIds.length} '
                      'transaction(s) · ${e.money!.status.name}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
              const SizedBox(height: 8),
              _sectionTitle(context, 'Time target'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Has time target'),
                value: _hasEffort,
                onChanged: (v) => setState(() => _hasEffort = v),
              ),
              if (_hasEffort) ...[
                TextField(
                  controller: _minutes,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Target minutes',
                    border: OutlineInputBorder(),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Fixed estimate'),
                  value: _effortFixed,
                  onChanged: (v) => setState(() => _effortFixed = v),
                ),
              ],
              const SizedBox(height: 8),
              _sectionTitle(context, 'Memorization (Anki)'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Has memorization target'),
                subtitle: const Text(
                  'Review N Anki cards per period — progress feeds from '
                  'AnkiConnect or manual counts',
                ),
                value: _hasAnki,
                onChanged: (v) => setState(() => _hasAnki = v),
              ),
              if (_hasAnki) ...[
                TextField(
                  controller: _deck,
                  decoration: const InputDecoration(
                    labelText: 'Deck (blank = all decks)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _targetReviews,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Target reviews',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<TimeScale?>(
                  initialValue: _ankiPeriod,
                  decoration: const InputDecoration(
                    labelText: 'Period (optional)',
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('One-time'),
                    ),
                    for (final s in TimeScale.values)
                      DropdownMenuItem(value: s, child: Text(s.displayName)),
                  ],
                  onChanged: (v) => setState(() => _ankiPeriod = v),
                ),
                if (_ankiPeriod == TimeScale.custom) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _ankiCustomDays,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Custom period (days)',
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                TextField(
                  controller: _manualReviews,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Reviews so far (this period)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 4),
                if (_ankiSyncedAt != null)
                  Text(
                    'Last counted '
                    '${MaterialLocalizations.of(context).formatFullDate(_ankiSyncedAt!)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _ankiSyncing ? null : () => _syncAnki(context),
                      icon: _ankiSyncing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync, size: 16),
                      label: const Text('Sync from Anki'),
                    ),
                    TextButton.icon(
                      onPressed: () => _importAnki(context),
                      icon: const Icon(Icons.upload_outlined, size: 16),
                      label: const Text('Paste stats'),
                    ),
                  ],
                ),
                if (kIsWeb)
                  Text(
                    'Sync from Anki goes through the app server here — '
                    'sign in first. Manual entry and pasted stats still '
                    'work offline.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
              const SizedBox(height: 8),
              _sectionTitle(context, 'Repeats'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Repeats'),
                subtitle: const Text(
                  'Habit/budget template — generates dated instances',
                ),
                value: _hasRecurrence,
                onChanged: (v) => setState(() => _hasRecurrence = v),
              ),
              if (_hasRecurrence) ...[
                DropdownButtonFormField<TimeScale>(
                  initialValue: _frequency,
                  decoration: const InputDecoration(labelText: 'Frequency'),
                  items: TimeScale.values
                      .map(
                        (s) => DropdownMenuItem(
                          value: s,
                          child: Text(s.displayName),
                        ),
                      )
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _frequency = v ?? _frequency),
                ),
                _DateRow(
                  label: _recurEnd == null
                      ? 'Repeats forever'
                      : 'Ends ${MaterialLocalizations.of(context).formatFullDate(_recurEnd!)}',
                  onPick: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate:
                          _recurEnd ??
                          DateTime.now().add(const Duration(days: 365)),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) {
                      setState(() => _recurEnd = picked);
                    }
                  },
                  onClear: _recurEnd == null
                      ? null
                      : () => setState(() => _recurEnd = null),
                ),
              ],
              ], // end if (_metrics.isEmpty): manual targets and repeats
              if (e?.rule != null) ...[
                const SizedBox(height: 8),
                _sectionTitle(context, 'Legacy rule'),
                DropdownButtonFormField<NodeRuleKind>(
                initialValue: _ruleKind,
                decoration: const InputDecoration(
                  labelText: 'Derived goal (optional)',
                ),
                items: const [
                  DropdownMenuItem(
                    value: NodeRuleKind.none,
                    child: Text('None'),
                  ),
                  DropdownMenuItem(
                    value: NodeRuleKind.homeworkAhead,
                    child: Text('Homework ahead'),
                  ),
                  DropdownMenuItem(
                    value: NodeRuleKind.minBalance,
                    child: Text('Minimum balance'),
                  ),
                ],
                onChanged: (v) =>
                    setState(() => _ruleKind = v ?? NodeRuleKind.none),
              ),
              if (_ruleKind == NodeRuleKind.homeworkAhead) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _horizon,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Days ahead that must be done',
                  ),
                ),
              ],
              if (_ruleKind == NodeRuleKind.minBalance) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _minBalance,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Floor balance',
                    prefixText: '\$ ',
                  ),
                ),
              ],
              ], // end if (e?.rule != null): legacy rule
            ], // end if (!_isUnbounded): dates, targets, repeats, rules
            if (_isUnbounded) ...[
              const SizedBox(height: 8),
              Text(
                'Add concrete subgoals underneath (e.g. “Serve others '
                'this week”) — they carry the dates and the progress.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (e != null &&
                (e.hasReported && e.reportedDuration != null ||
                    e.isTracking)) ...[
              const SizedBox(height: 8),
              Builder(
                builder: (context) {
                  // Live copy: a timer correction made in the edit sheet
                  // (opened below) shows here without reopening the editor.
                  Node live = e;
                  try {
                    live = context.watch<NodeCubit>().byId(e.id) ?? e;
                  } catch (_) {}
                  final trackingLine =
                      live.isTracking && live.timerStartedAt != null
                      ? 'Recording since ${DateFormat('h:mm a').format(live.timerStartedAt!)}'
                      : null;
                  final reportedLine =
                      live.hasReported &&
                          live.reportedDuration != null &&
                          live.actualStart != null &&
                          live.actualEnd != null
                      ? 'Reported ${live.reportedDuration!.inMinutes}m '
                            '(${DateFormat('h:mm a').format(live.actualStart!)} – '
                            '${DateFormat('h:mm a').format(live.actualEnd!)})'
                      : null;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (trackingLine != null)
                              Text(
                                trackingLine,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            if (reportedLine != null)
                              Text(
                                reportedLine,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () =>
                            showEditNodeTimerSheet(context, nodeId: e.id),
                        child: Text(
                          trackingLine != null ? 'Edit start' : 'Adjust',
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
            if (e != null && e.status == NodeStatus.failed) ...[
              const SizedBox(height: 4),
              Text(
                'Marked as failed — tap its box to unmark.',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        if (e != null)
          TextButton(
            onPressed: () => _delete(context, e),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => _save(context),
          child: Text(e == null ? 'Add' : 'Save'),
        ),
      ],
    );
  }

  String _className(BuildContext context) {
    try {
      final cubit = context.read<NodeCubit>();
      final id = _classNodeId ?? _classParentId(cubit);
      if (id == null) return 'None';
      return cubit.byId(id)?.title ?? 'Class not found';
    } catch (_) {
      return 'None';
    }
  }

  /// A class added through the Parents field is still class membership.
  /// The Class row reads it so "just add the class as a parent" works
  /// without a second selection.
  String? _classParentId(NodeCubit cubit) {
    for (final id in _parents) {
      if (cubit.byId(id)?.isClassNode == true) return id;
    }
    return null;
  }

  Future<void> _pickClass() async {
    final id = await showClassPicker(context, selectedId: _classNodeId);
    if (!mounted || id == null) return;
    setState(() => _classNodeId = id);
  }

  bool _hasChildren(BuildContext context) {
    final id = widget.existing?.id;
    if (id == null) return false;
    try {
      return context.read<NodeCubit>().childrenOf(id).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Homework classes already imported, used as metric chips. Reading
  /// cubits defensively keeps the editor usable in previews/tests where a
  /// provider is intentionally absent.
  List<String> _classOptions(BuildContext context) {
    try {
      final keys = <String>{};
      for (final node in context.read<NodeCubit>().state) {
        if (!node.isHomework) continue;
        final label = node.classLabel?.trim();
        final id = node.classId?.trim();
        final key = label != null && label.isNotEmpty ? label : id;
        if (key != null && key.isNotEmpty) keys.add(key);
      }
      return _sorted(keys);
    } catch (_) {
      return const [];
    }
  }

  List<String> _moneyCategoryOptions(BuildContext context) {
    try {
      final categories = {
        for (final txn in context.read<TransactionsCubit>().state)
          if (txn.category != null && txn.category!.trim().isNotEmpty)
            txn.category!.trim(),
      };
      return _sorted(categories);
    } catch (_) {
      return const [];
    }
  }

  static List<String> _sorted(Iterable<String> values) =>
      values.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  Widget _sectionTitle(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(fontWeight: FontWeight.bold),
    ),
  );

  void _save(BuildContext context) {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please enter a title')));
      return;
    }
    _saveConfirmed(context);
  }

  /// Class membership is a parent edge plus a stable `classNodeId`.
  /// Imported homework keeps its feed `classId`/`classLabel` provenance;
  /// manual work takes the class node's id/title so the Homework tab and
  /// time-by-class reporting group it correctly.
  ({
    List<String> parents,
    String? classNodeId,
    String? classId,
    String? classLabel,
    bool clearClassId,
    bool clearClassLabel,
  }) _classSaveValues(NodeCubit cubit, Node? existing) {
    final parents = [..._parents];
    final selectedClassId = _classNodeId;
    var classNode =
        selectedClassId == null ? null : cubit.byId(selectedClassId);
    classNode ??= () {
      for (final id in _parents) {
        final candidate = cubit.byId(id);
        if (candidate?.isClassNode == true) return candidate;
      }
      return null;
    }();
    if (existing?.isClassNode != true && existing?.isInstance != true) {
      parents.removeWhere((id) => cubit.byId(id)?.isClassNode == true);
      if (classNode != null && !parents.contains(classNode.id)) {
        parents.add(classNode.id);
      }
    }
    final imported = existing != null &&
        (existing.sourceEventId != null || existing.feedId != null);
    if (classNode != null) {
      return (
        parents: parents,
        classNodeId: classNode.id,
        classId: imported ? existing.classId : classNode.id,
        classLabel: imported
            ? (existing.classLabel ?? classNode.title)
            : classNode.title,
        clearClassId: false,
        clearClassLabel: false,
      );
    }
    final wasManualClass = existing?.classNodeId != null && !imported;
    return (
      parents: parents,
      classNodeId: null,
      classId: null,
      classLabel: null,
      clearClassId: wasManualClass,
      clearClassLabel: wasManualClass,
    );
  }

  /// Second half of [_save], after the unbounded-facets confirm dialog.
  /// Split out so the async confirm gate stays readable.
  Future<void> _saveConfirmed(BuildContext context) async {
    // The cubit is read before any await so no BuildContext crosses the
    // confirm dialog's async gap.
    final cubit = context.read<NodeCubit>();
    // Going unbounded drops dates/targets/repeats/rules. The hidden
    // sections' state is still in memory here, so confirm before the
    // save clears stored facets — one tap back to safety.
    if (_isUnbounded) {
      final dropping = <String>[];
      if (_due != null ||
          (widget.existing?.schedule?.hasCalendarBlock ?? false)) {
        dropping.add('schedule');
      }
      if (_hasMoney) dropping.add('money target');
      if (_hasEffort) dropping.add('time target');
      if (_hasAnki) dropping.add('memorization target');
      if (_hasRecurrence) dropping.add('repeats');
      if (_metrics.isNotEmpty) dropping.add('metrics');
      if (_ruleKind != NodeRuleKind.none) dropping.add('rule');
      if (dropping.isNotEmpty) {
        final drop = await _confirmDropFacets(context, dropping);
        if (!context.mounted) return;
        if (!drop) return;
      }
    }
    if (!context.mounted) return;
    final title = _title.text.trim();
    if (title.isEmpty) return; // guarded in [_save]; re-check after await.
    final notes = _notes.text.trim().isEmpty ? null : _notes.text.trim();
    final opening = widget.existing;
    // Re-read live: a timer correction (start edit / manual entry) or a
    // background link made while the editor was open must survive this
    // save — the snapshot from open time would otherwise clobber it.
    // Form-owned fields below still come from the controllers, so only
    // non-form state refreshes.
    final existing = opening == null ? null : cubit.byId(opening.id) ?? opening;

    // Day-only here: the due date is edited inline and any existing
    // calendar block is preserved. Times are calendar events picked
    // visually via Schedule → Time, never typed here.
    var schedule = scheduleAfterEditorSave(
      previous: existing?.schedule,
      due: _due,
      isFixed: _dateFixed,
    );

    MoneyFacet? money;
    if (_hasMoney) {
      final target = double.tryParse(_amount.text.trim()) ?? 0.0;
      money = MoneyFacet(
        targetAmount: target,
        actualAmount: existing?.money?.actualAmount,
        direction: _direction,
        status: existing?.money?.status ?? MoneyStatus.projected,
        period: _period,
        customPeriodDays: _period == TimeScale.custom
            ? int.tryParse(_customDaysCtrl.text.trim())
            : null,
        isRecurring: _moneyRecurring,
        autoRollover: _autoRollover,
        rolloverAmount: existing?.money?.rolloverAmount ?? 0.0,
        isFixed: _moneyFixed,
        linkedTransactionIds: existing?.money?.linkedTransactionIds ?? const [],
      );
    }

    EffortFacet? effort;
    if (_hasEffort) {
      effort = EffortFacet(
        targetMinutes: int.tryParse(_minutes.text.trim()) ?? 0,
        isFixed: _effortFixed,
      );
    }

    AnkiFacet? anki;
    if (_hasAnki) {
      final deck = _deck.text.trim();
      final manual = int.tryParse(_manualReviews.text.trim());
      anki = AnkiFacet(
        deckName: deck.isEmpty ? null : deck,
        targetReviews: int.tryParse(_targetReviews.text.trim()) ?? 0,
        period: _ankiPeriod,
        customPeriodDays: _ankiPeriod == TimeScale.custom
            ? int.tryParse(_ankiCustomDays.text.trim())
            : null,
        // A blank count keeps the previously synced number (or nothing
        // on a new goal) instead of zeroing it.
        reviewsActual: manual ?? existing?.anki?.reviewsActual,
        lastSyncedAt: manual != null ? DateTime.now() : _ankiSyncedAt,
      );
    }

    NodeRecurrence? recurrence;
    if (_hasRecurrence) {
      recurrence = NodeRecurrence(frequency: _frequency, endDate: _recurEnd);
    }

    RuleFacet? rule;
    if (_ruleKind != NodeRuleKind.none) {
      rule = RuleFacet(
        kind: _ruleKind,
        horizonDays: int.tryParse(_horizon.text.trim()) ?? 3,
        minBalance: double.tryParse(_minBalance.text.trim()) ?? 0.0,
      );
    }

    var auto = _metrics.isEmpty ? null : _metrics.first;
    var extraMetrics = _metrics.length <= 1
        ? const <AutoFacet>[]
        : _metrics.sublist(1);
    final classValues = _classSaveValues(cubit, existing);

    // Unbounded goals carry no dates, targets, repeats, rules, or
    // metrics — the hidden sections' stale state is dropped so the save
    // validates.
    final isUnbounded = _isUnbounded;
    if (isUnbounded) {
      schedule = null;
      money = null;
      effort = null;
      anki = null;
      recurrence = null;
      auto = null;
      extraMetrics = const [];
      rule = null;
    }

    String? error;
    Node? result;
    if (existing == null) {
      final node = Node(
        id: 'node:${DateTime.now().microsecondsSinceEpoch}',
        title: title,
        notes: notes,
        parentIds: classValues.parents,
        createdAt: DateTime.now(),
        isUnbounded: isUnbounded,
        isFavorite: _isFavorite,
        schedule: schedule,
        money: money,
        effort: effort,
        anki: anki,
        recurrence: recurrence,
        auto: auto,
        extraMetrics: extraMetrics,
        classNodeId: classValues.classNodeId,
        classId: classValues.classId,
        classLabel: classValues.classLabel,
        rule: rule,
        assignees: _people,
      );
      error = cubit.addNode(node);
      if (error == null) {
        result = node;
        if (recurrence != null) {
          cubit.generateInstances(
            templateId: node.id,
            from: DateTime.now(),
            horizon: DateTime.now().add(const Duration(days: 365)),
          );
        }
      }
    } else {
      // Built on the live copy so timer/reported edits made while the
      // editor was open survive (see above); every form-owned field is
      // still set explicitly from the controllers.
      final updated = existing.copyWith(
        title: title,
        notes: notes,
        clearNotes: notes == null,
        parentIds: classValues.parents,
        isUnbounded: isUnbounded,
        isFavorite: _isFavorite,
        schedule: schedule,
        clearSchedule: schedule == null,
        money: money,
        clearMoney: money == null,
        effort: effort,
        clearEffort: effort == null,
        anki: anki,
        clearAnki: anki == null,
        recurrence: recurrence,
        clearRecurrence: recurrence == null,
        auto: auto,
        clearAuto: auto == null,
        extraMetrics: extraMetrics,
        classNodeId: classValues.classNodeId,
        clearClassNodeId: classValues.classNodeId == null,
        classId: classValues.classId,
        clearClassId: classValues.clearClassId,
        classLabel: classValues.classLabel,
        clearClassLabel: classValues.clearClassLabel,
        rule: rule,
        clearRule: rule == null,
        assignees: _people,
      );
      error = cubit.updateNode(updated);
      if (error == null) result = updated;
    }
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    Navigator.of(context).pop(result);
  }

  /// Pulls today's review count from AnkiConnect into the manual field.
  /// Native builds call AnkiConnect directly; the web build goes through
  /// the app server (browsers cannot reach AnkiConnect themselves).
  Future<void> _syncAnki(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    String host = '';
    try {
      host = context.read<SettingsCubit>().state.ankiConnectHost;
    } catch (_) {}
    final deck = _deck.text.trim();
    setState(() => _ankiSyncing = true);
    try {
      final int count;
      if (kIsWeb) {
        count = await ankiServerReviewsToday(
          context.read<AuthCubit>().syncClient,
          deck: deck.isEmpty ? null : deck,
        );
      } else {
        final client = AnkiConnectClient(host: host, httpClient: http.Client());
        try {
          count = await client.reviewsToday(deck: deck.isEmpty ? null : deck);
        } finally {
          client.close();
        }
      }
      if (!context.mounted) return;
      setState(() {
        _manualReviews.text = count.toString();
        _ankiSyncedAt = DateTime.now();
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Anki: $count card${count == 1 ? '' : 's'} reviewed today',
          ),
        ),
      );
    } on AnkiServerException catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } on AnkiException catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (context.mounted) setState(() => _ankiSyncing = false);
    }
  }

  /// Pastes "deck,count per line" stats (see parseAnkiReviewCounts) into
  /// the manual field. The fallback for web and mobile-only users.
  Future<void> _importAnki(BuildContext context) async {
    final pasted = TextEditingController();
    final result = await showDialog<AnkiImportResult>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste Anki stats'),
        content: TextField(
          controller: pasted,
          maxLines: 6,
          decoration: const InputDecoration(
            hintText: '42\nJapanese, 30',
            helperText:
                'One count per line: "42" or "Deck, 42". '
                'Lines starting with # are ignored.',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              try {
                Navigator.of(ctx).pop(parseAnkiReviewCounts(pasted.text));
              } on FormatException catch (e) {
                ScaffoldMessenger.of(ctx)
                    .showSnackBar(SnackBar(content: Text(e.message)));
              }
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    pasted.dispose();
    if (result == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      // A single named deck fills the deck field too (when blank); mixed
      // pastes apply the total and leave the deck alone.
      final named = result.byDeck.keys.where((k) => k != '*').toList();
      if (named.length == 1 && _deck.text.trim().isEmpty) {
        _deck.text = named.single;
        _manualReviews.text = result.byDeck[named.single].toString();
      } else {
        _manualReviews.text = result.total.toString();
      }
      _ankiSyncedAt = DateTime.now();
    });
    messenger.showSnackBar(
      SnackBar(content: Text('Pasted ${result.total} reviews')),
    );
  }

  /// Confirm gate before an unbounded save clears dates/targets. Returns
  /// true when the user accepts the removal.
  Future<bool> _confirmDropFacets(
    BuildContext context,
    List<String> dropping,
  ) async {
    final drop = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove dates and targets?'),
        content: Text(
          'Saving as an unbounded goal removes this goal\u2019s '
          '${dropping.join(', ')}. Subgoals keep their own dates.\n\n'
          'You can still Undo right after saving.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove and save'),
          ),
        ],
      ),
    );
    return drop ?? false;
  }

  void _delete(BuildContext context, Node existing) {
    // Capture everything up front: the dialog is popped BEFORE the banner
    // shows. Showing an action SnackBar from a dialog and popping in the
    // same frame leaves it up forever (its auto-dismiss never fires), so
    // the old order stuck a permanent 'Node deleted' banner on screen.
    // The old code also read UndoCubit through this (soon unmounted)
    // context, which threw on Undo.
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final nodes = context.read<NodeCubit>();
    final undo = context.read<UndoCubit>();
    CalendarCubit? calendar;
    try {
      calendar = context.read<CalendarCubit>();
    } catch (_) {}
    TransactionsCubit? transactions;
    try {
      transactions = context.read<TransactionsCubit>();
    } catch (_) {}
    try {
      if (transactions == null) {
        if (calendar == null) {
          nodes.deleteNode(existing.id);
        } else {
          NodeEventLink.deleteNodesAndUnlink(nodes, calendar, {existing.id});
        }
      } else {
        deleteNodesAndClearAssignments(
          nodes: nodes,
          transactions: transactions,
          delete: () {
            if (calendar == null) {
              nodes.deleteNode(existing.id);
            } else {
              NodeEventLink.deleteNodesAndUnlink(
                nodes,
                calendar,
                {existing.id},
              );
            }
            return null;
          },
        );
      }
    } catch (_) {
      nodes.deleteNode(existing.id);
    }
    navigator.pop();
    // Replace any banner still up from an earlier delete: queued
    // snackbars each linger 4s and stack into one that won't go away.
    // persist: false is required: a SnackBar with an action persists
    // forever by default, which stuck this banner on screen.
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Node deleted'),
          duration: const Duration(seconds: 4),
          persist: false,
          action: SnackBarAction(label: 'Undo', onPressed: undo.undo),
        ),
      );
  }
}

class _DateRow extends StatelessWidget {
  final String label;
  final VoidCallback onPick;
  final VoidCallback? onClear;

  const _DateRow({required this.label, required this.onPick, this.onClear});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(
          tooltip: 'Pick date',
          icon: const Icon(Icons.event),
          onPressed: onPick,
        ),
        if (onClear != null)
          IconButton(
            tooltip: 'Clear date',
            icon: const Icon(Icons.event_busy),
            onPressed: onClear,
          ),
      ],
    );
  }
}
