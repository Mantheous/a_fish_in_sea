import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/tasks_view_options_cubit.dart';
import '../model/task_filter.dart';
import '../model/task_rule.dart';
import 'task_selector_form.dart';

/// Fixed tint choices for highlight rules. Null is the theme-default tint
/// (the legacy week look); rows due today always glow orange on top.
const taskRuleTintChoices = <int?>[
  null,
  0xFFFF9800,
  0xFF42A5F5,
  0xFF66BB6A,
  0xFFAB47BC,
  0xFFEC407A,
];

/// Builder for one display rule: the selector ("which tasks") plus the
/// effect ("highlight this color" or "hide them"). New rules default to a
/// week highlight, on.
Future<void> showTaskRuleEditor(
  BuildContext context, {
  TaskRule? existing,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => _TaskRuleEditorSheet(existing: existing),
  );
}

class _TaskRuleEditorSheet extends StatefulWidget {
  final TaskRule? existing;

  const _TaskRuleEditorSheet({this.existing});

  @override
  State<_TaskRuleEditorSheet> createState() => _TaskRuleEditorSheetState();
}

class _TaskRuleEditorSheetState extends State<_TaskRuleEditorSheet> {
  late TaskFilter _selector;
  late bool _enabled;
  late TaskRuleEffect _effect;
  late int? _colorValue;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _selector = e?.selector ??
        TaskFilter(
          id: TaskRule.newId(),
          name: 'New rule',
          date: TaskFilterDate.thisWeek,
        );
    _enabled = e?.enabled ?? true;
    _effect = e?.effect ?? TaskRuleEffect.highlight;
    _colorValue = e?.colorValue;
  }

  TaskRule _draft() => TaskRule(
        id: widget.existing?.id ?? _selector.id,
        enabled: _enabled,
        selector: _selector,
        effect: _effect,
        colorValue: _effect == TaskRuleEffect.highlight ? _colorValue : null,
      );

  void _save() {
    try {
      final cubit = context.read<TasksViewOptionsCubit>();
      final draft = _draft();
      if (widget.existing == null) {
        cubit.addRule(draft);
      } else {
        cubit.updateRule(draft);
      }
    } catch (_) {}
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    final draft = _draft();
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
                      existing == null ? 'New rule' : 'Edit rule',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (existing != null)
                    TextButton(
                      onPressed: () {
                        try {
                          context
                              .read<TasksViewOptionsCubit>()
                              .deleteRule(existing.id);
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
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _enabled,
                    onChanged: (v) => setState(() => _enabled = v),
                    title: const Text('Rule on'),
                    subtitle: const Text(
                        'Off rules stay saved but change nothing.'),
                  ),
                  Text('When tasks match,',
                      style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  SegmentedButton<TaskRuleEffect>(
                    segments: const [
                      ButtonSegment(
                          value: TaskRuleEffect.highlight,
                          label: Text('Highlight')),
                      ButtonSegment(
                          value: TaskRuleEffect.hide, label: Text('Hide')),
                    ],
                    selected: {_effect},
                    onSelectionChanged: (s) =>
                        setState(() => _effect = s.single),
                  ),
                  if (_effect == TaskRuleEffect.highlight) ...[
                    const SizedBox(height: 12),
                    _TintPicker(
                      selected: _colorValue,
                      onPick: (c) => setState(() => _colorValue = c),
                    ),
                    Text(
                      'Open rows in the window get a tinted row and a '
                      'colored edge — rows due today glow orange on top.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    Text(
                      'Hide mode: matching rows leave both lists until '
                      'the rule is switched off. Hiding always wins over '
                      'highlighting.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text('Which tasks',
                      style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  TaskSelectorForm(
                    value: _selector,
                    onChanged: (next) => setState(() => _selector = next),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    describeTaskRule(draft),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _save,
                    child: Text(existing == null ? 'Add rule' : 'Save'),
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

class _TintPicker extends StatelessWidget {
  final int? selected;
  final ValueChanged<int?> onPick;

  const _TintPicker({required this.selected, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final choice in taskRuleTintChoices)
          _Swatch(
            color:
                choice == null ? theme.colorScheme.tertiary : Color(choice),
            tooltip: choice == null
                ? 'Theme tint'
                : 'Tint ${choice.toRadixString(16)}',
            selected: selected == choice,
            onTap: () => onPick(choice),
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final String tooltip;
  final bool selected;
  final VoidCallback? onTap;

  const _Swatch({
    required this.color,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outlineVariant,
              width: selected ? 3 : 1,
            ),
          ),
          child: selected
              ? Icon(Icons.check,
                  size: 18, color: Theme.of(context).colorScheme.onPrimary)
              : null,
        ),
      ),
    );
  }
}
