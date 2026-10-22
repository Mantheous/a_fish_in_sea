import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/tasks_view_options_cubit.dart';
import '../model/task_rule.dart';
import 'task_rule_editor_sheet.dart';

/// Dedicated page for adjusting the Tasks display rules, opened from the
/// view-options sheet's "Edit rules" button. Each rule is a selector
/// ("which tasks") plus a visual change ("highlight this color" or
/// "hide them"). Rules run top to bottom: hiding always wins over
/// tinting, and the topmost matching highlight wins the tint — drag the
/// handle to change priority.
Future<void> showTaskRulesPage(BuildContext context) {
  return Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const TaskRulesPage()),
  );
}

class TaskRulesPage extends StatelessWidget {
  const TaskRulesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<TasksViewOptionsCubit>().state;
    final cubit = context.read<TasksViewOptionsCubit>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Task rules'),
        actions: [
          IconButton(
            tooltip: 'New rule',
            icon: const Icon(Icons.add),
            onPressed: () => showTaskRuleEditor(context),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Rules run top to bottom. Hiding always wins over '
              'highlighting; the topmost matching highlight wins the '
              'tint. Drag the handle to change priority.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: state.rules.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.tune_outlined, size: 48),
                        const SizedBox(height: 8),
                        Text('No rules',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 4),
                        const Text(
                            'Everything shows as the view leaves it.'),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: () => showTaskRuleEditor(context),
                          icon: const Icon(Icons.add),
                          label: const Text('New rule'),
                        ),
                      ],
                    ),
                  )
                : ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: state.rules.length,
                    onReorderItem: (oldIndex, newIndex) {
                      cubit.moveRule(oldIndex, newIndex);
                    },
                    itemBuilder: (context, index) {
                      final rule = state.rules[index];
                      return _RuleTile(
                        key: ValueKey(rule.id),
                        index: index,
                        rule: rule,
                        onTap: () => showTaskRuleEditor(
                          context,
                          existing: rule,
                        ),
                        onEnabled: (v) =>
                            cubit.setRuleEnabled(rule.id, v),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: state.rules.isEmpty
          ? null
          : FloatingActionButton(
              tooltip: 'New rule',
              onPressed: () => showTaskRuleEditor(context),
              child: const Icon(Icons.add),
            ),
    );
  }
}

class _RuleTile extends StatelessWidget {
  final int index;
  final TaskRule rule;
  final VoidCallback onTap;
  final ValueChanged<bool> onEnabled;

  const _RuleTile({
    super.key,
    required this.index,
    required this.rule,
    required this.onTap,
    required this.onEnabled,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _EffectIcon(rule: rule),
      title: Text(rule.name),
      subtitle: Text(describeTaskRule(rule)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: rule.enabled,
            onChanged: onEnabled,
          ),
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.drag_handle),
            ),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// Shared leading icon for a rule: an eye-off for hides, the tint dot
/// for highlights.
class _EffectIcon extends StatelessWidget {
  final TaskRule rule;

  const _EffectIcon({required this.rule});

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
