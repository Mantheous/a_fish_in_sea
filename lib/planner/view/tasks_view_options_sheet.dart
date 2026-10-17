import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/tasks_view_options_cubit.dart';
import '../model/task_filter.dart';
import '../model/task_rule.dart';
import 'task_filter_editor_sheet.dart';
import 'task_rule_editor_sheet.dart';
import 'task_rules_page.dart';

Future<void> showTasksViewOptions(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => const _TasksViewOptionsSheet(),
  );
}

class _TasksViewOptionsSheet extends StatelessWidget {
  const _TasksViewOptionsSheet();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<TasksViewOptionsCubit>().state;
    final cubit = context.read<TasksViewOptionsCubit>();
    final canClear = state.hasActiveOptions ||
        state.hasCustomFilters ||
        state.hasCustomRules ||
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
              'A view hides everything outside it. Rules tint or hide '
              'matching rows on top of the view — nothing is added or '
              'synced.',
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
                    'Rules',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(
                    'Each rule highlights or hides the tasks it matches. '
                    'Hiding always wins; the topmost matching highlight '
                    'wins the tint.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                for (final rule in state.rules)
                  _RuleRow(
                    rule: rule,
                    onToggled: (v) => cubit.setRuleEnabled(rule.id, v),
                    onTap: () => showTaskRuleEditor(
                      context,
                      existing: rule,
                    ),
                  ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => showTaskRuleEditor(context),
                        icon: const Icon(Icons.add),
                        label: const Text('New rule'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => showTaskRulesPage(context),
                        icon: const Icon(Icons.tune_outlined),
                        label: const Text('Edit rules'),
                      ),
                    ],
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

/// A rule row: tap opens the editor, the switch toggles the rule.
class _RuleRow extends StatelessWidget {
  final TaskRule rule;
  final ValueChanged<bool> onToggled;
  final VoidCallback onTap;

  const _RuleRow({
    required this.rule,
    required this.onToggled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: _RuleEffectIcon(rule: rule),
      title: Text(rule.name),
      subtitle: Text(describeTaskRule(rule)),
      trailing: Switch(
        value: rule.enabled,
        onChanged: onToggled,
      ),
      onTap: onTap,
    );
  }
}

/// Leading tint dot for highlight rules, eye-off for hide rules.
class _RuleEffectIcon extends StatelessWidget {
  final TaskRule rule;

  const _RuleEffectIcon({required this.rule});

  @override
  Widget build(BuildContext context) {
    if (rule.isHide) {
      return Icon(
        Icons.visibility_off_outlined,
        color: Theme.of(context).colorScheme.outline,
      );
    }
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: rule.colorValue == null
            ? Theme.of(context).colorScheme.tertiary
            : Color(rule.colorValue!),
        shape: BoxShape.circle,
      ),
    );
  }
}
