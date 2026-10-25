import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/parent_candidates.dart';

final _dateFormat = DateFormat('EEE, MMM d');

/// How many rows the picker shows before the user types. Recent goals are
/// the useful default; the rest stay one search away.
const int _recentLimit = 4;

/// How many matches a search shows. The editor is a scrolling form, so a
/// plain column beats a nested list viewport (which cannot be measured
/// inside an [AlertDialog]).
const int _searchLimit = 12;

/// Parent chips plus an inline "add parent" search for the node editor.
///
/// Laid out like the contacts field (`PeopleField`): selected parents sit in
/// chips, a search box follows, and tapping a result adds it immediately.
/// The list opens on the goals the user touched most recently, one row per
/// repeating series — a habit's generated occurrences are not separate
/// parents and cannot be picked at all.
class ParentsField extends StatefulWidget {
  final List<String> selected;

  /// The node being edited (null for a new node); hidden from the picker
  /// together with its descendants so the pick cannot create a cycle.
  final String? excludeId;
  final ValueChanged<List<String>> onChanged;

  const ParentsField({
    super.key,
    required this.selected,
    required this.excludeId,
    required this.onChanged,
  });

  @override
  State<ParentsField> createState() => _ParentsFieldState();
}

class _ParentsFieldState extends State<ParentsField> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _add(Node node) {
    if (widget.selected.contains(node.id)) return;
    widget.onChanged([...widget.selected, node.id]);
  }

  void _remove(String id) =>
      widget.onChanged(widget.selected.where((p) => p != id).toList());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = context.watch<NodeCubit>().state;
    final byId = {for (final n in all) n.id: n};
    final editing = widget.excludeId == null ? null : byId[widget.excludeId!];
    // A generated occurrence is owned by its template and may not gain
    // other parents, so every pick here would fail validation.
    final isInstance = editing?.instanceOfId != null;
    final candidates = isInstance
        ? const <ParentCandidate>[]
        : parentCandidates(all, excludeId: widget.excludeId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Parents', style: theme.textTheme.labelLarge),
        if (widget.selected.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final id in widget.selected)
                _ParentChip(
                  label: byId[id]?.title ?? 'node',
                  node: byId[id],
                  onDeleted: isInstance ? null : () => _remove(id),
                ),
            ],
          ),
        ],
        if (isInstance)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Generated occurrence — it stays under its repeating goal. '
              'Edit that goal to move the whole series.',
              style: theme.textTheme.bodySmall,
            ),
          )
        else ...[
          const SizedBox(height: 6),
          TextField(
            controller: _search,
            decoration: const InputDecoration(
              hintText: 'Search goals',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 6),
          _buildResults(theme, candidates),
        ],
      ],
    );
  }

  Widget _buildResults(ThemeData theme, List<ParentCandidate> candidates) {
    if (candidates.isEmpty) {
      return Text(
        'No eligible parents — add another goal first.',
        style: theme.textTheme.bodySmall,
      );
    }
    final query = _search.text.trim().toLowerCase();
    final matches = query.isEmpty
        ? candidates
        : candidates
              .where(
                (c) =>
                    c.node.title.toLowerCase().contains(query) ||
                    (c.node.notes?.toLowerCase().contains(query) ?? false),
              )
              .toList();
    if (matches.isEmpty) {
      return Text(
        'No goals match "${_search.text.trim()}".',
        style: theme.textTheme.bodySmall,
      );
    }
    final shown = query.isEmpty
        ? matches.take(_recentLimit)
        : matches.take(_searchLimit);
    final shownList = shown.toList();
    final hidden = matches.length - shownList.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final candidate in shownList) _resultRow(context, candidate),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              query.isEmpty
                  ? '$hidden more — type to search.'
                  : '$hidden more — narrow the search.',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _resultRow(BuildContext context, ParentCandidate candidate) {
    final node = candidate.node;
    final added = widget.selected.contains(node.id);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(radius: 14, child: Icon(_iconFor(node), size: 15)),
      title: Text(node.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        _subtitle(candidate),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: added
          ? const Icon(Icons.check, size: 18)
          : const Icon(Icons.add, size: 18),
      onTap: added ? null : () => _add(node),
    );
  }

  static String _subtitle(ParentCandidate candidate) {
    final node = candidate.node;
    final parts = <String>[];
    final recurrence = node.recurrence;
    if (recurrence != null) {
      parts.add('Repeats ${_repeatLabel(recurrence)}');
      if (candidate.occurrences > 0) {
        parts.add(_occurrenceLabel(candidate.occurrences));
      }
    } else if (candidate.occurrences > 0) {
      parts.add('Repeating');
      parts.add(_occurrenceLabel(candidate.occurrences));
    } else if (node.isUnbounded) {
      parts.add('Ongoing goal');
    } else if (node.isClassNode) {
      parts.add('Class');
    }
    final due = node.schedule?.due;
    final start = node.schedule?.start;
    if (due != null) {
      parts.add('due ${_dateFormat.format(due)}');
    } else if (start != null) {
      parts.add('scheduled ${_dateFormat.format(start)}');
    }
    if (parts.isEmpty) {
      parts.add('Added ${_dateFormat.format(node.createdAt)}');
    }
    return parts.join(' · ');
  }

  static String _repeatLabel(NodeRecurrence recurrence) {
    if (recurrence.frequency == TimeScale.custom) {
      final days = recurrence.customPeriodDays ?? 0;
      if (days > 0) return 'every $days day${days == 1 ? '' : 's'}';
    }
    return recurrence.frequency.displayName.toLowerCase();
  }

  static String _occurrenceLabel(int count) =>
      '$count occurrence${count == 1 ? '' : 's'}';
}

class _ParentChip extends StatelessWidget {
  final String label;
  final Node? node;
  final VoidCallback? onDeleted;

  const _ParentChip({
    required this.label,
    required this.node,
    required this.onDeleted,
  });

  @override
  Widget build(BuildContext context) {
    return InputChip(
      avatar: CircleAvatar(radius: 10, child: Icon(_iconFor(node), size: 12)),
      label: Text(label, overflow: TextOverflow.ellipsis),
      onDeleted: onDeleted,
    );
  }
}

IconData _iconFor(Node? node) {
  if (node == null) return Icons.flag_outlined;
  if (node.isUnbounded) return Icons.all_inclusive;
  if (node.isClassNode) return Icons.school_outlined;
  if (node.isTemplate || node.recurrence != null) return Icons.repeat_outlined;
  if (node.hasMetrics) return Icons.auto_graph;
  if (node.hasMoney) return Icons.savings_outlined;
  if (node.hasEffort || node.hasCalendarBlock) return Icons.timer_outlined;
  return Icons.flag_outlined;
}
