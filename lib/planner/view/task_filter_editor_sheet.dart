import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/tasks_view_options_cubit.dart';
import '../model/task_filter.dart';
import 'task_selector_form.dart';

/// Builder for one saved Tasks view: name plus the selector rules (date
/// window, status, kind, classes, planning). The All/Today/Overdue presets
/// open here too — they are just editable views. Display rules (tint or
/// hide on top of the active view) live in the rule editor instead.
Future<void> showTaskFilterEditor(
  BuildContext context, {
  TaskFilter? existing,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => _TaskFilterEditorSheet(existing: existing),
  );
}

class _TaskFilterEditorSheet extends StatefulWidget {
  final TaskFilter? existing;

  const _TaskFilterEditorSheet({this.existing});

  @override
  State<_TaskFilterEditorSheet> createState() => _TaskFilterEditorSheetState();
}

class _TaskFilterEditorSheetState extends State<_TaskFilterEditorSheet> {
  late TaskFilter _draft;

  bool get _editingAll => widget.existing?.id == 'all';

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _draft = e ??
        TaskFilter(
          id: TaskFilter.newId(),
          name: 'Custom filter',
          date: TaskFilterDate.next7Days,
        );
  }

  void _save() {
    try {
      final cubit = context.read<TasksViewOptionsCubit>();
      if (widget.existing == null) {
        cubit.addFilter(_draft);
      } else {
        cubit.updateFilter(_draft);
        cubit.setActiveFilter(_draft.id);
      }
    } catch (_) {}
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      existing == null ? 'New filter' : 'Edit filter',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (existing != null && !_editingAll)
                    TextButton(
                      onPressed: () {
                        try {
                          context
                              .read<TasksViewOptionsCubit>()
                              .deleteFilter(existing.id);
                        } catch (_) {}
                        Navigator.of(context).pop();
                      },
                      child: const Text('Delete'),
                    ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  TaskSelectorForm(
                    value: _draft,
                    onChanged: (next) => setState(() => _draft = next),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _save,
                    child: Text(existing == null ? 'Add filter' : 'Save'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
