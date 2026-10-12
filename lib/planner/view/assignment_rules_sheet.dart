import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../common/undo/undo_cubit.dart';
import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/model/node.dart';
import '../bloc/assignment_rules_cubit.dart';
import '../bloc/feed_cubit.dart';
import '../model/assignment_rule.dart';
import '../model/assignment_template.dart';

/// Repeating-assignment rules, opened from the ⋮ menu on the Tasks page.
///
/// One rule governs one repeating type inside one class (feed + template
/// key): its offset shifts the deadline the app plans around — negative
/// is earlier, so e.g. MATH 290 video quizzes set −2 days surface in
/// Today/Home before they are actually due. Fresh imports shift
/// automatically; existing items shift through the explicit Apply
/// buttons (each a single undoable write), and deleting a rule offers to
/// move applied items back. Hand-edited dues are never touched: bulk
/// moves only target items sitting exactly on the feed date (offset 0)
/// or on the rule's own offset.
Future<void> showAssignmentRules(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => const _AssignmentRulesSheet(),
  );
}

class _AssignmentRulesSheet extends StatelessWidget {
  const _AssignmentRulesSheet();

  @override
  Widget build(BuildContext context) {
    final rulesCubit = context.watch<AssignmentRulesCubit>();
    final rules = rulesCubit.state;
    final nodes = context.watch<NodeCubit>().state;
    final feeds = context.watch<FeedCubit>().state;
    final feedNames = {for (final f in feeds) f.id: f.name};

    final samples = <TemplateSample>[
      for (final n in nodes)
        if (n.sourceEventId != null &&
            n.schedule?.due != null &&
            (n.feedId ?? n.classId ?? '').isNotEmpty)
          TemplateSample(
            feedId: (n.feedId ?? n.classId)!,
            title: n.title,
            classLabel: n.classLabel,
            due: n.schedule!.due,
          ),
    ];
    final groups = detectRepeatingGroups(samples);
    final ruedKeys = {for (final r in rules) r.groupKey};
    final unruled =
        groups.where((g) => !ruedKeys.contains('${g.feedId}|${g.templateKey}'));

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
                    'Assignment rules',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
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
              'Repeating types — weekly quizzes, problem sets — can be '
              'due earlier or later in your plan than the class feed says. '
              'New imports shift automatically; use Apply for items that '
              'are already here. Deleting a rule can move items back.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (rules.isNotEmpty) ...[
                  _SectionLabel('Your rules (${rules.length})'),
                  for (final rule in rules)
                    _RuleRow(
                      rule: rule,
                      nodes: nodes,
                      feedName: feedNames[rule.feedId],
                    ),
                ],
                _SectionLabel(unruled.isEmpty && rules.isEmpty
                    ? 'Repeating types'
                    : 'Detected types'),
                if (groups.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Text(
                      'No repeating types detected yet. Sync a class with '
                      'several similar assignments — three or more of a '
                      'kind, roughly evenly spaced, counts as repeating.',
                    ),
                  )
                else
                  for (final group in groups)
                    if (!ruedKeys
                        .contains('${group.feedId}|${group.templateKey}'))
                      _GroupRow(
                        group: group,
                        feedName: feedNames[group.feedId],
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge),
      );
}

String _classDisplay(String? classLabel, String? feedName) =>
    classLabel ?? feedName ?? 'Unknown class';

/// Pending/applied counts for one rule over open homework nodes.
({int pending, int applied}) _ruleCounts(
    AssignmentRule rule, List<Node> nodes) {
  var pending = 0;
  var applied = 0;
  for (final n in nodes) {
    if (n.sourceEventId == null || !n.isOpen) continue;
    if ((n.feedId ?? n.classId) != rule.feedId) continue;
    if (assignmentTemplateKey(n.title) != rule.templateKey) continue;
    final s = n.schedule;
    final base = assignmentBaseDue(
      start: s?.start,
      end: s?.end,
      allDay: s?.allDay ?? false,
    );
    final shift = assignmentShiftOf(due: s?.due, base: base);
    if (shift == null) continue;
    if (shift == 0) {
      pending++;
    } else if (shift == rule.dueOffsetDays) {
      applied++;
    }
  }
  return (pending: pending, applied: applied);
}

void _showUndoneSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 4),
        persist: false,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            try {
              context.read<UndoCubit>().undo();
            } catch (_) {}
          },
        ),
      ),
    );
}

class _RuleRow extends StatelessWidget {
  final AssignmentRule rule;
  final List<Node> nodes;
  final String? feedName;
  const _RuleRow(
      {required this.rule, required this.nodes, required this.feedName});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<AssignmentRulesCubit>();
    final nodeCubit = context.read<NodeCubit>();
    final counts = _ruleCounts(rule, nodes);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        rule.displayName,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        _classDisplay(rule.classLabel, feedName),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                _OffsetChip(days: rule.dueOffsetDays),
                IconButton(
                  tooltip: 'Delete rule',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () =>
                      _confirmDelete(context, cubit, nodeCubit, counts),
                ),
              ],
            ),
            _OffsetStepper(
              value: rule.dueOffsetDays,
              onChanged: (v) {
                if (v == rule.dueOffsetDays) return;
                final old = rule.dueOffsetDays;
                cubit.upsertRule(rule.copyWith(dueOffsetDays: v));
                // Keep already-shifted items on the new offset instead of
                // stranding them on the old one.
                final moved = nodeCubit.retargetAssignmentDues(
                  feedId: rule.feedId,
                  templateKey: rule.templateKey,
                  newOffsetDays: v,
                  fromOffsets: [old],
                );
                if (moved > 0 && context.mounted) {
                  _showUndoneSnack(
                      context, 'Moved $moved existing to ${describeDueOffset(v)}');
                }
              },
            ),
            if (counts.pending > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: Text(
                      'Apply to ${counts.pending} existing (${describeDueOffset(rule.dueOffsetDays)})'),
                  onPressed: rule.dueOffsetDays == 0
                      ? null
                      : () {
                          final moved =
                              nodeCubit.retargetAssignmentDues(
                            feedId: rule.feedId,
                            templateKey: rule.templateKey,
                            newOffsetDays: rule.dueOffsetDays,
                          );
                          if (context.mounted) {
                            _showUndoneSnack(context,
                                moved > 0 ? 'Applied to $moved' : 'Nothing to apply');
                          }
                        },
                ),
              )
            else if (counts.applied > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${counts.applied} existing ${counts.applied == 1 ? 'item' : 'items'} on this offset.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    AssignmentRulesCubit cubit,
    NodeCubit nodeCubit,
    ({int pending, int applied}) counts,
  ) async {
    if (counts.applied == 0) {
      cubit.deleteRule(rule.id);
      return;
    }
    final moveBack = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete rule?'),
        content: Text(
          '${counts.applied} existing ${counts.applied == 1 ? 'item' : 'items'} '
          '${counts.applied == 1 ? 'is' : 'are'} on ${describeDueOffset(rule.dueOffsetDays)}. '
          'Move ${counts.applied == 1 ? 'it' : 'them'} back to the feed date?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep dates'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Move back'),
          ),
        ],
      ),
    );
    if (moveBack == null) return;
    if (moveBack) {
      final moved = nodeCubit.retargetAssignmentDues(
        feedId: rule.feedId,
        templateKey: rule.templateKey,
        newOffsetDays: 0,
        fromOffsets: [rule.dueOffsetDays],
      );
      cubit.deleteRule(rule.id);
      if (context.mounted && moved > 0) {
        _showUndoneSnack(context, 'Moved $moved back to feed dates');
      }
    } else {
      cubit.deleteRule(rule.id);
    }
  }
}

class _GroupRow extends StatefulWidget {
  final AssignmentGroup group;
  final String? feedName;
  const _GroupRow({required this.group, required this.feedName});

  @override
  State<_GroupRow> createState() => _GroupRowState();
}

class _GroupRowState extends State<_GroupRow> {
  bool _adding = false;
  int _draft = -1;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final cadence = describeCadence(group.medianGapDays);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.displayName,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        '${_classDisplay(group.classLabel, widget.feedName)}'
                        ' · ×${group.count}'
                        '${group.isRepeating ? ' · repeating' : ''}'
                        '${cadence == null ? '' : ' · $cadence'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (!_adding)
                  TextButton(
                    onPressed: () => setState(() => _adding = true),
                    child: const Text('Add rule'),
                  ),
              ],
            ),
            if (_adding) ...[
              _OffsetStepper(
                value: _draft,
                onChanged: (v) => setState(() => _draft = v),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => setState(() => _adding = false),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _draft == 0
                        ? null
                        : () {
                            final rulesCubit =
                                context.read<AssignmentRulesCubit>();
                            final nodeCubit = context.read<NodeCubit>();
                            final rule = rulesCubit.createRule(
                              feedId: group.feedId,
                              templateKey: group.templateKey,
                              displayName: group.displayName,
                              dueOffsetDays: _draft,
                              classLabel: group.classLabel,
                            );
                            final moved =
                                nodeCubit.retargetAssignmentDues(
                              feedId: rule.feedId,
                              templateKey: rule.templateKey,
                              newOffsetDays: rule.dueOffsetDays,
                            );
                            if (context.mounted) {
                              setState(() => _adding = false);
                              _showUndoneSnack(
                                context,
                                moved > 0
                                    ? 'Rule saved — applied to $moved existing'
                                    : 'Rule saved — new imports will shift',
                              );
                            }
                          },
                    child: const Text('Save rule'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OffsetChip extends StatelessWidget {
  final int days;
  const _OffsetChip({required this.days});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Chip(
      label: Text(compactDueOffset(days)),
      visualDensity: VisualDensity.compact,
      backgroundColor: days == 0 ? null : scheme.secondaryContainer,
    );
  }
}

/// − value + stepper over −14..+14 days with a plain-language label.
class _OffsetStepper extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  const _OffsetStepper({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          tooltip: 'Due earlier',
          icon: const Icon(Icons.remove),
          onPressed:
              value > -14 ? () => onChanged(value - 1) : null,
        ),
        Expanded(
          child: Text(
            describeDueOffset(value),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        IconButton(
          tooltip: 'Due later',
          icon: const Icon(Icons.add),
          onPressed: value < 14 ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }
}
