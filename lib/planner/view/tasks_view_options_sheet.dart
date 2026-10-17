import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/tasks_view_options_cubit.dart';
import '../model/task_filter.dart';
import 'task_filter_editor_sheet.dart';

Future<void> showTasksViewOptions(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => const _TasksViewOptionsSheet(),
  );
}

/// Fixed tint choices for the highlight rule. Null is the theme-default
/// tint (the legacy week look); rows due today always glow orange on top.
const _tintChoices = <int?>[
  null,
  0xFFFF9800,
  0xFF42A5F5,
  0xFF66BB6A,
  0xFFAB47BC,
  0xFFEC407A,
];

class _TasksViewOptionsSheet extends StatelessWidget {
  const _TasksViewOptionsSheet();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<TasksViewOptionsCubit>().state;
    final cubit = context.read<TasksViewOptionsCubit>();
    final canClear = state.hasActiveOptions ||
        state.hasCustomFilters ||
        state.activeFilterId != 'all';
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
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
                    'View options',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                TextButton(
                  onPressed: canClear ? cubit.clearAll : null,
                  child: const Text('Clear'),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'A view hides everything outside it — including completed '
              'and undated items, unless the view says otherwise. The '
              'highlight only adds a cue (or hides, in Hide mode). '
              'Nothing is added or synced.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    'Views',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                for (final filter in state.filters)
                  _ViewTile(
                    filter: filter,
                    active: filter.id == state.activeFilterId,
                    onTap: () => cubit.setActiveFilter(filter.id),
                    onEdit: () => showTaskFilterEditor(
                      context,
                      existing: filter,
                    ),
                  ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => showTaskFilterEditor(context),
                        icon: const Icon(Icons.add),
                        label: const Text('New filter'),
                      ),
                      if (state.hasCustomFilters)
                        TextButton(
                          onPressed: cubit.clearAll,
                          child: const Text('Reset to defaults'),
                        ),
                    ],
                  ),
                ),
                const Divider(indent: 16, endIndent: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    'Highlight',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                SwitchListTile(
                  value: state.highlight.enabled,
                  onChanged: cubit.setHighlightEnabled,
                  secondary: const Icon(Icons.date_range_outlined),
                  title: Text(
                    state.highlight.hideMatching
                        ? 'Hide matching items'
                        : 'Highlight matching items',
                  ),
                  subtitle: const Text(
                    'Tinted rows keep their list; hidden rows leave it. '
                    'Pick Hide below to hide instead of tint.',
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: DropdownButtonFormField<TaskHighlightDate>(
                    initialValue: state.highlight.date,
                    decoration: const InputDecoration(
                      labelText: 'Highlight window',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final d in TaskHighlightDate.values)
                        DropdownMenuItem(
                          value: d,
                          child: Text(taskHighlightDateLabel(d)),
                        ),
                    ],
                    onChanged: state.highlight.enabled
                        ? (d) {
                            if (d != null) cubit.setHighlightDate(d);
                          }
                        : null,
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: _ColorRow(
                    enabled: state.highlight.enabled,
                    selected: state.highlight.hideMatching
                        ? _HideSelected.hide
                        : _HideSelected.show,
                    colorValue: state.highlight.colorValue,
                    onPickColor: (c) {
                      cubit.setHighlightHideMatching(false);
                      cubit.setHighlightColor(c);
                    },
                    onPickHide: () => cubit.setHighlightHideMatching(true),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: Text(
                    state.highlight.hideMatching
                        ? 'Hide mode: open items in the window leave both '
                            'lists until you switch back.'
                        : 'Open items in the window get a tinted row and a '
                            'colored edge — items due today glow orange.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _HideSelected { show, hide }

class _ViewTile extends StatelessWidget {
  final TaskFilter filter;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  const _ViewTile({
    required this.filter,
    required this.active,
    required this.onTap,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(
        active
            ? Icons.radio_button_checked
            : Icons.radio_button_unchecked,
        color: active ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(filter.name),
      subtitle: Text(describeTaskFilter(filter)),
      trailing: IconButton(
        tooltip: 'Edit ${filter.name}',
        icon: const Icon(Icons.edit_outlined),
        onPressed: onEdit,
      ),
      selected: active,
      onTap: onTap,
    );
  }
}

class _ColorRow extends StatelessWidget {
  final bool enabled;
  final _HideSelected selected;
  final int? colorValue;
  final ValueChanged<int?> onPickColor;
  final VoidCallback onPickHide;

  const _ColorRow({
    required this.enabled,
    required this.selected,
    required this.colorValue,
    required this.onPickColor,
    required this.onPickHide,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final choice in _tintChoices)
            _Swatch(
              color: choice == null ? theme.colorScheme.tertiary : Color(choice),
              tooltip: choice == null
                  ? 'Theme tint'
                  : 'Tint ${choice.toRadixString(16)}',
              selected:
                  selected == _HideSelected.show && colorValue == choice,
              onTap: enabled ? () => onPickColor(choice) : null,
            ),
          _HideSwatch(
            selected: selected == _HideSelected.hide,
            onTap: enabled ? onPickHide : null,
          ),
        ],
      ),
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

class _HideSwatch extends StatelessWidget {
  final bool selected;
  final VoidCallback? onTap;

  const _HideSwatch({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Hide instead of tint',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 3 : 1,
            ),
          ),
          child: Icon(
            Icons.visibility_off_outlined,
            size: 18,
            color: selected ? scheme.primary : scheme.outline,
          ),
        ),
      ),
    );
  }
}
