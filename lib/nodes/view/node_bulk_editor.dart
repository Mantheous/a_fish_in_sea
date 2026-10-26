import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../planner/model/task_assignee.dart';
import '../../planner/view/people_field.dart';
import '../bloc/node_cubit.dart';
import '../model/node.dart';
import '../service/node_bulk_edit.dart';
import 'class_picker.dart';
import 'node_bulk_editor_fields.dart';
import 'node_editor_date_row.dart';
import 'node_editor_side_sheet.dart';
import 'parents_field.dart';

/// Shows the bulk editor for [nodes]. Returns the number of goals updated,
/// or null when the panel was cancelled.
///
/// Titles stay individual (the field is disabled); every other section is
/// opt-in, so opening the panel and saving changes nothing.
Future<int?> showNodeBulkEditor(
  BuildContext context, {
  required List<Node> nodes,
}) {
  if (nodes.isEmpty) return Future<int?>.value(null);
  _BulkEditor buildEditor() => _BulkEditor(nodes: nodes);
  if (MediaQuery.sizeOf(context).width >= nodeEditorSideSheetBreakpoint) {
    return showGeneralDialog<int>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close bulk editor',
      barrierColor: Colors.black.withValues(alpha: 0.24),
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (dialogContext, animation, secondaryAnimation) =>
          buildEditor(),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return SlideTransition(
          position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
              .animate(
                CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                  reverseCurve: Curves.easeInCubic,
                ),
              ),
          child: child,
        );
      },
    );
  }
  return showDialog<int>(
    context: context,
    builder: (dialogContext) => buildEditor(),
  );
}

class _BulkEditor extends StatefulWidget {
  const _BulkEditor({required this.nodes});

  final List<Node> nodes;

  @override
  State<_BulkEditor> createState() => _BulkEditorState();
}

class _BulkEditorState extends State<_BulkEditor> {
  late final TextEditingController _notes;
  late final TextEditingController _effort;

  bool _applyNotes = false;
  bool _applyParents = false;
  bool _applyPeople = false;
  bool _applyClass = false;
  bool _applyDue = false;
  bool _applyEffort = false;

  List<String> _addParents = const [];
  String? _removeParentId;
  List<TaskAssignee> _people = const [];
  String? _classNodeId;
  DateTime? _due;
  bool? _unbounded;
  bool? _favorite;
  bool? _task;

  @override
  void initState() {
    super.initState();
    _notes = TextEditingController();
    _effort = TextEditingController();
  }

  @override
  void dispose() {
    _notes.dispose();
    _effort.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.nodes.length;
    final title = Text('Edit $count goal${count == 1 ? '' : 's'}');
    if (MediaQuery.sizeOf(context).width >= nodeEditorSideSheetBreakpoint) {
      return NodeEditorSideSheet(
        title: title,
        form: _form(context),
        actions: _actions(context),
      );
    }
    return AlertDialog(
      title: title,
      content: SingleChildScrollView(child: _form(context)),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: _actions(context),
    );
  }

  Widget _form(BuildContext context) {
    final theme = Theme.of(context);
    final cubit = context.watch<NodeCubit>();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Only the fields you switch on are applied. Titles stay '
          'individual.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        const TextField(
          key: ValueKey('bulk-title'),
          enabled: false,
          decoration: InputDecoration(
            labelText: 'Title',
            hintText: 'Titles stay individual',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        BulkToggleTile(
          key: const ValueKey('bulk-notes-toggle'),
          title: 'Notes',
          subtitle: 'Replace every selected goal’s notes (blank clears)',
          value: _applyNotes,
          onChanged: (v) => setState(() => _applyNotes = v),
        ),
        if (_applyNotes) _notesField(context),
        BulkToggleTile(
          key: const ValueKey('bulk-people-toggle'),
          title: 'People',
          subtitle: 'Replace the assignee list on every selected goal',
          value: _applyPeople,
          onChanged: (v) => setState(() => _applyPeople = v),
        ),
        if (_applyPeople)
          PeopleField(
            selected: _people,
            onChanged: (next) => setState(() => _people = next),
          ),
        BulkToggleTile(
          key: const ValueKey('bulk-parents-toggle'),
          title: 'Parents',
          subtitle: 'Add and/or remove one parent without replacing the rest',
          value: _applyParents,
          onChanged: (v) => setState(() => _applyParents = v),
        ),
        if (_applyParents) _parentsFields(context, cubit),
        const SizedBox(height: 8),
        bulkSectionTitle(context, 'Flags'),
        BulkTriStateField(
          key: const ValueKey('bulk-unbounded'),
          label: 'Abstract / unbounded goal',
          value: _unbounded,
          onChanged: (v) => setState(() => _unbounded = v),
        ),
        BulkTriStateField(
          key: const ValueKey('bulk-favorite'),
          label: 'Favorite goal',
          value: _favorite,
          onChanged: (v) => setState(() => _favorite = v),
        ),
        BulkTriStateField(
          key: const ValueKey('bulk-task'),
          label: 'Task',
          value: _task,
          onChanged: _unbounded == true
              ? null
              : (v) => setState(() => _task = v),
        ),
        if (_unbounded == true)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              'Unbounded goals cannot be tasks. Saving drops schedules, '
              'money/time/Anki targets, metrics, repeats and rules on the '
              'selected goals.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        const SizedBox(height: 8),
        BulkToggleTile(
          key: const ValueKey('bulk-class-toggle'),
          title: 'Class',
          subtitle: _applyClass
              ? _classLabel(cubit)
              : 'Set or clear class membership on every selected goal',
          value: _applyClass,
          onChanged: (v) => setState(() => _applyClass = v),
        ),
        if (_applyClass) _classFields(context),
        if (_unbounded != true) ...[
          BulkToggleTile(
            key: const ValueKey('bulk-due-toggle'),
            title: 'Due date',
            subtitle: !_applyDue
                ? 'Set one due date on every selected goal'
                : _due == null
                ? 'No due date (clears due dates)'
                : 'Due ${MaterialLocalizations.of(context).formatFullDate(_due!)}',
            value: _applyDue,
            onChanged: (v) => setState(() => _applyDue = v),
          ),
          if (_applyDue) _dueField(context),
          BulkToggleTile(
            key: const ValueKey('bulk-effort-toggle'),
            title: 'Time target',
            subtitle: 'Set the same target minutes (blank clears)',
            value: _applyEffort,
            onChanged: (v) => setState(() => _applyEffort = v),
          ),
          if (_applyEffort) _effortField(context),
        ],
        const SizedBox(height: 12),
        Text(
          'Money, Anki, metrics, repeats and derived rules stay per goal.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _notesField(BuildContext context) {
    return TextField(
      key: const ValueKey('bulk-notes-field'),
      controller: _notes,
      maxLines: 3,
      decoration: const InputDecoration(
        labelText: 'Notes',
        hintText: 'Applied to every selected goal',
        border: OutlineInputBorder(),
      ),
    );
  }

  Widget _parentsFields(BuildContext context, NodeCubit cubit) {
    final live = [for (final node in widget.nodes) cubit.byId(node.id) ?? node];
    final parentIds = <String>{for (final node in live) ...node.parentIds};
    final parents = [
      for (final id in parentIds)
        if (cubit.byId(id) case final parent?) parent,
    ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Add parents', style: Theme.of(context).textTheme.labelLarge),
        ParentsField(
          selected: _addParents,
          excludeId: null,
          onChanged: (next) => setState(() => _addParents = next),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: const ValueKey('bulk-remove-parent'),
          initialValue: _removeParentId,
          decoration: const InputDecoration(
            labelText: 'Remove parent (optional)',
          ),
          items: [
            const DropdownMenuItem(value: null, child: Text('Keep parents')),
            for (final parent in parents)
              DropdownMenuItem(
                value: parent.id,
                child: Text(parent.title, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (next) => setState(() => _removeParentId = next),
        ),
      ],
    );
  }

  String _classLabel(NodeCubit cubit) {
    final id = _classNodeId;
    if (id == null) return 'No class (clears class membership)';
    return cubit.byId(id)?.title ?? 'Class not found';
  }

  Widget _classFields(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.school_outlined),
      title: Text(_classLabel(context.read<NodeCubit>())),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Clear class',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _classNodeId = null),
          ),
          IconButton(
            tooltip: 'Pick class',
            icon: const Icon(Icons.arrow_drop_down),
            onPressed: _pickClass,
          ),
        ],
      ),
    );
  }

  Widget _dueField(BuildContext context) {
    return NodeEditorDateRow(
      label: _due == null
          ? 'No due date'
          : 'Due ${MaterialLocalizations.of(context).formatFullDate(_due!)}',
      onPick: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: _due ?? DateTime.now(),
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
        if (picked != null) setState(() => _due = picked);
      },
      onClear: _due == null ? null : () => setState(() => _due = null),
    );
  }

  Widget _effortField(BuildContext context) {
    return TextField(
      key: const ValueKey('bulk-effort-minutes'),
      controller: _effort,
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(
        labelText: 'Target minutes',
        hintText: 'Blank clears the time target',
        border: OutlineInputBorder(),
      ),
    );
  }

  Future<void> _pickClass() async {
    final id = await showClassPicker(context, selectedId: _classNodeId);
    if (!mounted || id == null) return;
    setState(() => _classNodeId = id);
  }

  List<Widget> _actions(BuildContext context) {
    return [
      TextButton(
        key: const ValueKey('bulk-cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('bulk-apply'),
        onPressed: () => _apply(context),
        child: Text('Apply to ${widget.nodes.length}'),
      ),
    ];
  }

  Future<void> _apply(BuildContext context) async {
    final cubit = context.read<NodeCubit>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final notes = _notes.text;
    final minutes = int.tryParse(_effort.text.trim());
    final edits = NodeBulkEdits(
      applyNotes: _applyNotes,
      notes: notes,
      applyParents: _applyParents,
      addParentIds: _addParents,
      removeParentId: _removeParentId,
      applyPeople: _applyPeople,
      people: _people,
      unbounded: _unbounded,
      favorite: _favorite,
      task: _task,
      applyClass: _applyClass,
      classNodeId: _classNodeId,
      applyDue: _applyDue,
      due: _due,
      applyEffort: _applyEffort,
      effortMinutes: minutes,
    );
    if (!edits.applyNotes &&
        !edits.applyParents &&
        !edits.applyPeople &&
        edits.unbounded == null &&
        edits.favorite == null &&
        edits.task == null &&
        !edits.applyClass &&
        !edits.applyDue &&
        !edits.applyEffort) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Switch on at least one field')),
        );
      return;
    }
    if (_unbounded == true && _dropsFacets(cubit)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Make these goals unbounded?'),
          content: const Text(
            'Saving as unbounded removes schedules, money/time/Anki '
            'targets, metrics, repeats and rules from the selected goals. '
            'You can undo right after saving.',
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
      if (!mounted || confirmed != true) return;
    }
    // Never resurrect a goal deleted while the panel was open: writeNodes
    // treats an unknown id as an insert, so only live nodes are candidates.
    final live = [
      for (final node in widget.nodes)
        if (cubit.byId(node.id) case final current?) current,
    ];
    if (live.isEmpty) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Those goals no longer exist')),
        );
      return;
    }
    final byId = {for (final node in cubit.state) node.id: node};
    final upserts = applyBulkEdits(live, edits, byId: byId);
    if (upserts.isEmpty) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Those goals already match')),
        );
      return;
    }
    final errors = cubit.writeNodes(upserts: upserts);
    if (errors.isNotEmpty) {
      final applied = upserts.length - errors.length;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              applied == 0
                  ? 'Nothing updated. ${errors.values.first}'
                  : 'Updated $applied of ${upserts.length} goals. '
                        '${errors.values.first}',
            ),
          ),
        );
      return;
    }
    navigator.pop(upserts.length);
  }

  bool _dropsFacets(NodeCubit cubit) {
    for (final node in widget.nodes) {
      final live = cubit.byId(node.id) ?? node;
      if (live.schedule != null ||
          live.money != null ||
          live.effort != null ||
          live.anki != null ||
          live.hasMetrics ||
          live.recurrence != null ||
          (live.rule?.kind ?? NodeRuleKind.none) != NodeRuleKind.none) {
        return true;
      }
    }
    return false;
  }
}
