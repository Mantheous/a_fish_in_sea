import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/nodes/service/node_progress.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';

final _goalPickerDateFormat = DateFormat('EEE, MMM d');

/// Picks a goal (a user-built [Node], never imported homework or calendar
/// links) to parent something under. Generated instances are excluded —
/// they cannot have children of their own. Returns the picked goal, or
/// null when the dialog is dismissed.
///
/// [excludeNodeId] (plus its descendants) is hidden so the pick cannot
/// create a cycle.
Future<Node?> showGoalPicker(
  BuildContext context, {
  String? excludeNodeId,
  String title = 'Assign to goal',
}) async {
  List<Node> all;
  try {
    all = context.read<NodeCubit>().state;
  } catch (_) {
    return null;
  }
  final goals = goalNodes(all)
      .where((n) => n.instanceOfId == null)
      .toList()
    ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  final hidden = <String>{};
  if (excludeNodeId != null) {
    hidden.add(excludeNodeId);
    hidden.addAll(descendantIds(excludeNodeId, all));
  }
  final candidates =
      goals.where((n) => !hidden.contains(n.id)).toList();
  if (candidates.isEmpty || !context.mounted) return null;
  return showDialog<Node?>(
    context: context,
    builder: (ctx) => _GoalPickerDialog(
      title: title,
      candidates: candidates,
    ),
  );
}

/// Picks one repeating calendar event to assign to a goal. Series with
/// several cached occurrences are grouped into a single row; the caller
/// assigns the whole series. Returns the seed event, or null when the
/// dialog is dismissed.
Future<PlannerEvent?> showRepeatingEventPicker(BuildContext context) async {
  List<PlannerEvent> events;
  try {
    events = context.read<CalendarCubit>().state;
  } catch (_) {
    return null;
  }
  final repeating = events
      .where((e) =>
          !e.id.startsWith('node:') &&
          !e.id.startsWith('report:') &&
          NodeEventLink.isRepeatingEvent(e))
      .toList();
  if (repeating.isEmpty || !context.mounted) return null;
  // One row per series: instances share their master's key, personal
  // repeats are singletons.
  final seenKeys = <String>{};
  final seeds = <PlannerEvent>[];
  final counts = <String, int>{};
  for (final e in repeating) {
    final key = NodeEventLink.seriesKeyOf(e) ?? 'event:${e.id}';
    counts[key] = (counts[key] ?? 0) + 1;
    if (seenKeys.add(key)) seeds.add(e);
  }
  seeds.sort((a, b) => a.start.compareTo(b.start));
  return showDialog<PlannerEvent?>(
    context: context,
    builder: (ctx) => _EventPickerDialog(seeds: seeds, counts: counts),
  );
}

class _GoalPickerDialog extends StatefulWidget {
  final String title;
  final List<Node> candidates;

  const _GoalPickerDialog({required this.title, required this.candidates});

  @override
  State<_GoalPickerDialog> createState() => _GoalPickerDialogState();
}

class _GoalPickerDialogState extends State<_GoalPickerDialog> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? widget.candidates
        : widget.candidates
            .where((n) =>
                n.title.toLowerCase().contains(q) ||
                (n.notes?.toLowerCase().contains(q) ?? false))
            .toList();
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Search goals',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: shown.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No goals match.'),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: shown.length,
                      itemBuilder: (context, index) {
                        final n = shown[index];
                        return ListTile(
                          dense: true,
                          leading: n.isUnbounded
                              ? const Icon(Icons.all_inclusive, size: 20)
                              : const Icon(Icons.flag_outlined, size: 20),
                          title: Text(
                            n.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            _goalSubtitle(n),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => Navigator.of(context).pop(n),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  static String _goalSubtitle(Node n) {
    if (n.isUnbounded) {
      return n.parentIds.isEmpty
          ? 'unbounded'
          : 'unbounded · ${n.parentIds.length} parent(s)';
    }
    final due = n.schedule?.due;
    if (due != null) return 'due ${_goalPickerDateFormat.format(due)}';
    if (n.hasCalendarBlock) {
      return 'scheduled ${_goalPickerDateFormat.format(n.schedule!.start!)}';
    }
    if (n.isTemplate) return 'repeating template';
    return 'goal';
  }
}

class _EventPickerDialog extends StatefulWidget {
  final List<PlannerEvent> seeds;
  final Map<String, int> counts;

  const _EventPickerDialog({required this.seeds, required this.counts});

  @override
  State<_EventPickerDialog> createState() => _EventPickerDialogState();
}

class _EventPickerDialogState extends State<_EventPickerDialog> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? widget.seeds
        : widget.seeds
            .where((e) =>
                e.subject.toLowerCase().contains(q) ||
                (e.notes?.toLowerCase().contains(q) ?? false))
            .toList();
    return AlertDialog(
      title: const Text('Assign repeating event'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Search events',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: shown.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No repeating events match.'),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: shown.length,
                      itemBuilder: (context, index) {
                        final e = shown[index];
                        final key = NodeEventLink.seriesKeyOf(e) ??
                            'event:${e.id}';
                        final count = widget.counts[key] ?? 1;
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.repeat, size: 20),
                          title: Text(
                            e.subject,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            count > 1
                                ? '${_eventWhen(e)} · $count on calendar${e.isTask ? ' · task' : ''}'
                                : '${_eventWhen(e)}${e.isTask ? ' · task' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => Navigator.of(context).pop(e),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  static String _eventWhen(PlannerEvent e) {
    if (e.allDay) return _goalPickerDateFormat.format(e.start);
    final time = DateFormat('h:mm a');
    return '${_goalPickerDateFormat.format(e.start)} · ${time.format(e.start)}';
  }
}
