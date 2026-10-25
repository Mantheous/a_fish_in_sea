import 'package:flutter/material.dart';

import '../model/node.dart';
import '../service/goal_graph_filter.dart';

/// Opens the goal filter menu. Returns the new filter, or null when the
/// sheet was dismissed without applying one.
Future<GoalGraphFilter?> showGoalFilterSheet(
  BuildContext context, {
  required GoalGraphFilter filter,
  required List<Node> nodes,
  required DateTime now,
  String query = '',
}) {
  return showModalBottomSheet<GoalGraphFilter>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) =>
        _GoalFilterSheet(filter: filter, nodes: nodes, now: now, query: query),
  );
}

/// The active filter as removable chips under the search field. Keeps the
/// graph from hiding goals silently: every condition stays on screen and
/// can be dropped one at a time.
class GoalFilterSummaryBar extends StatelessWidget {
  const GoalFilterSummaryBar({
    super.key,
    required this.filter,
    required this.topicTitle,
    required this.onChanged,
  });

  final GoalGraphFilter filter;

  /// Title of [GoalGraphFilter.topicRootId], for the chip label.
  final String? topicTitle;
  final ValueChanged<GoalGraphFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    if (!filter.isActive) return const SizedBox.shrink();
    final chips = <Widget>[];
    if (filter.date != GoalDateFilter.any) {
      chips.add(
        InputChip(
          key: const ValueKey('goal-filter-chip-date'),
          label: Text(goalDateFilterLabel(filter.date)),
          onDeleted: () => onChanged(filter.withoutDate()),
        ),
      );
    }
    final topic = filter.topicRootId;
    if (topic != null) {
      chips.add(
        InputChip(
          key: const ValueKey('goal-filter-chip-topic'),
          avatar: const Icon(Icons.account_tree_outlined, size: 16),
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: Text(
              topicTitle ?? 'Topic',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          onDeleted: () => onChanged(filter.withoutTopic()),
        ),
      );
    }
    if (filter.kind != GoalKindFilter.any) {
      chips.add(
        InputChip(
          key: const ValueKey('goal-filter-chip-kind'),
          label: Text(goalKindFilterLabel(filter.kind)),
          onDeleted: () => onChanged(filter.withoutKind()),
        ),
      );
    }
    final status = filter.status;
    if (status != null) {
      chips.add(
        InputChip(
          key: const ValueKey('goal-filter-chip-status'),
          label: Text('Status: ${nodeStatusLabel(status)}'),
          onDeleted: () => onChanged(filter.withoutStatus()),
        ),
      );
    }
    if (filter.starredOnly) {
      chips.add(
        InputChip(
          key: const ValueKey('goal-filter-chip-starred'),
          avatar: const Icon(Icons.star, size: 16),
          label: const Text('Starred'),
          onDeleted: () => onChanged(filter.withoutStarred()),
        ),
      );
    }
    chips.add(
      ActionChip(
        key: const ValueKey('goal-filter-clear-all'),
        avatar: const Icon(Icons.filter_alt_off_outlined, size: 16),
        label: const Text('Clear'),
        onPressed: () => onChanged(const GoalGraphFilter()),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(spacing: 8, runSpacing: 4, children: chips),
      ),
    );
  }
}

/// Short label for the graph stats pill; callers join them themselves.
String goalFilterSummary(GoalGraphFilter filter, {String? topicTitle}) {
  final parts = <String>[];
  if (filter.date != GoalDateFilter.any) {
    parts.add(goalDateFilterLabel(filter.date).toLowerCase());
  }
  if (filter.topicRootId != null) {
    parts.add('topic: ${topicTitle ?? 'branch'}');
  }
  if (filter.kind != GoalKindFilter.any) {
    parts.add(goalKindFilterLabel(filter.kind).toLowerCase());
  }
  if (filter.status != null) {
    parts.add(nodeStatusLabel(filter.status!).toLowerCase());
  }
  if (filter.starredOnly) parts.add('starred');
  return parts.isEmpty ? 'filtered' : parts.join(' · ');
}

String goalDateFilterLabel(GoalDateFilter date) => switch (date) {
  GoalDateFilter.any => 'Any date',
  GoalDateFilter.overdue => 'Overdue',
  GoalDateFilter.today => 'Today',
  GoalDateFilter.thisWeek => 'This week',
  GoalDateFilter.thisMonth => 'This month',
  GoalDateFilter.noDate => 'No date',
};

String goalKindFilterLabel(GoalKindFilter kind) => switch (kind) {
  GoalKindFilter.any => 'Any type',
  GoalKindFilter.task => 'Tasks',
  GoalKindFilter.money => 'Money',
  GoalKindFilter.time => 'Time',
  GoalKindFilter.repeating => 'Repeating',
  GoalKindFilter.automated => 'Automated',
  GoalKindFilter.homework => 'Homework',
  GoalKindFilter.anki => 'Anki',
  GoalKindFilter.unbounded => 'Unbounded',
};

String nodeStatusLabel(NodeStatus status) => switch (status) {
  NodeStatus.open => 'Open',
  NodeStatus.done => 'Done',
  NodeStatus.failed => 'Failed',
  NodeStatus.skipped => 'Skipped',
};

class _GoalFilterSheet extends StatefulWidget {
  const _GoalFilterSheet({
    required this.filter,
    required this.nodes,
    required this.now,
    required this.query,
  });

  final GoalGraphFilter filter;
  final List<Node> nodes;
  final DateTime now;
  final String query;

  @override
  State<_GoalFilterSheet> createState() => _GoalFilterSheetState();
}

class _GoalFilterSheetState extends State<_GoalFilterSheet> {
  late GoalGraphFilter _draft = widget.filter;
  late final List<Node> _topics = goalTopicOptions(widget.nodes);

  int get _matchCount => filterGoalGraph(
    nodes: widget.nodes,
    now: widget.now,
    filter: _draft,
    query: widget.query,
  ).matchedIds.length;

  void _set(GoalGraphFilter next) => setState(() => _draft = next);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Filter goals',
                      style: theme.textTheme.titleLarge,
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
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Section(
                      title: 'Date',
                      children: [
                        for (final value in GoalDateFilter.values)
                          ChoiceChip(
                            key: ValueKey('goal-filter-date-${value.name}'),
                            label: Text(goalDateFilterLabel(value)),
                            selected: _draft.date == value,
                            onSelected: (_) =>
                                _set(_draft.copyWith(date: value)),
                          ),
                      ],
                    ),
                    if (_topics.length > 1)
                      _Section(
                        title: 'Topic (branch)',
                        caption:
                            'Goals have no tags here — a topic is a branch '
                            'of your tree.',
                        children: [
                          ChoiceChip(
                            key: const ValueKey('goal-filter-topic-any'),
                            label: const Text('All topics'),
                            selected: _draft.topicRootId == null,
                            onSelected: (_) =>
                                _set(_draft.copyWith(clearTopicRoot: true)),
                          ),
                          for (final topic in _topics)
                            ChoiceChip(
                              key: ValueKey('goal-filter-topic-${topic.id}'),
                              label: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 210,
                                ),
                                child: Text(
                                  topic.title.isEmpty
                                      ? '(untitled)'
                                      : topic.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              selected: _draft.topicRootId == topic.id,
                              onSelected: (_) =>
                                  _set(_draft.copyWith(topicRootId: topic.id)),
                            ),
                        ],
                      ),
                    _Section(
                      title: 'Type',
                      children: [
                        for (final value in GoalKindFilter.values)
                          ChoiceChip(
                            key: ValueKey('goal-filter-kind-${value.name}'),
                            label: Text(goalKindFilterLabel(value)),
                            selected: _draft.kind == value,
                            onSelected: (_) =>
                                _set(_draft.copyWith(kind: value)),
                          ),
                      ],
                    ),
                    _Section(
                      title: 'Status',
                      children: [
                        ChoiceChip(
                          key: const ValueKey('goal-filter-status-any'),
                          label: const Text('Any status'),
                          selected: _draft.status == null,
                          onSelected: (_) =>
                              _set(_draft.copyWith(clearStatus: true)),
                        ),
                        for (final value in NodeStatus.values)
                          ChoiceChip(
                            key: ValueKey('goal-filter-status-${value.name}'),
                            label: Text(nodeStatusLabel(value)),
                            selected: _draft.status == value,
                            onSelected: (_) =>
                                _set(_draft.copyWith(status: value)),
                          ),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      key: const ValueKey('goal-filter-starred'),
                      title: const Text('Starred only'),
                      subtitle: const Text('Keep the goals you pinned'),
                      value: _draft.starredOnly,
                      onChanged: (value) =>
                          _set(_draft.copyWith(starredOnly: value)),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '$_matchCount goal${_matchCount == 1 ? '' : 's'} match',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('goal-filter-clear'),
                    onPressed: () =>
                        Navigator.of(context).pop(const GoalGraphFilter()),
                    child: const Text('Clear all'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('goal-filter-apply'),
                    onPressed: () => Navigator.of(context).pop(_draft),
                    child: const Text('Apply'),
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

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.caption});

  final String title;
  final String? caption;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (caption != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                caption!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 6, children: children),
        ],
      ),
    );
  }
}
