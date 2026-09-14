import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/node_event_link.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';

/// Stops a recording timer (if running) and asks what to do next.
Future<void> stopNodeAndFinish(BuildContext context, String nodeId) async {
  Node? node;
  try {
    node = context.read<NodeCubit>().byId(nodeId);
  } catch (_) {
    return;
  }
  if (node == null) return;
  if (node.isTracking) {
    try {
      context.read<NodeCubit>().stopTracking(nodeId);
    } catch (_) {}
  }
  if (!context.mounted) return;
  await showNodeFinishSheet(context, nodeId: nodeId);
}

Future<void> showNodeFinishSheet(
  BuildContext context, {
  required String nodeId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => _FinishSheet(nodeId: nodeId),
  );
}

Future<void> showFollowUpScheduler(
  BuildContext context, {
  required String nodeId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: _FollowUpSheet(nodeId: nodeId),
    ),
  );
}

class _FinishSheet extends StatelessWidget {
  final String nodeId;

  const _FinishSheet({required this.nodeId});

  @override
  Widget build(BuildContext context) {
    Node? node;
    try {
      node = context.watch<NodeCubit>().byId(nodeId);
    } catch (_) {}
    if (node == null) {
      return const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('This node was deleted.'),
        ),
      );
    }
    final theme = Theme.of(context);
    final timeFormat = DateFormat('h:mm a');
    final reported = node.reportedDuration;
    final reportedLine = reported != null &&
            node.actualStart != null &&
            node.actualEnd != null
        ? 'Recorded ${timeFormat.format(node.actualStart!)} – '
            '${timeFormat.format(node.actualEnd!)} (${reported.inMinutes}m)'
        : 'Recording saved.';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Work session saved',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(node.title, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 4),
            Text(reportedLine, style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                try {
                  final nodes = context.read<NodeCubit>();
                  final current = nodes.byId(nodeId);
                  if (current != null && !current.isDone) {
                    NodeEventLink.toggleNodeDone(
                      nodes,
                      context.read<CalendarCubit>(),
                      nodeId,
                    );
                  }
                } catch (_) {}
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Mark complete'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                try {
                  NodeEventLink.setNodeFailed(
                    context.read<NodeCubit>(),
                    context.read<CalendarCubit>(),
                    nodeId,
                    true,
                  );
                } catch (_) {}
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.cancel_outlined, size: 18),
              label: const Text('Mark failed'),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                showFollowUpScheduler(context, nodeId: nodeId);
              },
              icon: const Icon(Icons.schedule, size: 18),
              label: const Text('Schedule follow-up'),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FollowUpSheet extends StatefulWidget {
  final String nodeId;

  const _FollowUpSheet({required this.nodeId});

  @override
  State<_FollowUpSheet> createState() => _FollowUpSheetState();
}

class _FollowUpSheetState extends State<_FollowUpSheet> {
  late DateTime _date;
  late TimeOfDay _start;
  late TimeOfDay _end;

  @override
  void initState() {
    super.initState();
    DateTime base = DateTime.now().add(const Duration(days: 1));
    TimeOfDay start = const TimeOfDay(hour: 9, minute: 0);
    try {
      final node = context.read<NodeCubit>().byId(widget.nodeId);
      final planned = node?.schedule?.start;
      if (planned != null) {
        base = planned.add(const Duration(days: 1));
        start = TimeOfDay.fromDateTime(planned);
      } else if (node?.schedule?.due != null) {
        base = node!.schedule!.due!;
        start = TimeOfDay.fromDateTime(node.schedule!.due!);
      }
    } catch (_) {}
    _date = DateTime(base.year, base.month, base.day);
    _start = start;
    final endMinutes = _start.hour * 60 + _start.minute + 60;
    _end = TimeOfDay(hour: (endMinutes ~/ 60) % 24, minute: endMinutes % 60);
  }

  DateTime get _startDateTime => DateTime(
        _date.year,
        _date.month,
        _date.day,
        _start.hour,
        _start.minute,
      );

  DateTime get _endDateTime {
    var end = DateTime(
      _date.year,
      _date.month,
      _date.day,
      _end.hour,
      _end.minute,
    );
    if (!end.isAfter(_startDateTime)) {
      end = _startDateTime.add(const Duration(hours: 1));
    }
    return end;
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('EEE, MMM d, yyyy');
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Schedule follow-up',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Sets the next planned work block on this node.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) setState(() => _date = picked);
              },
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Date'),
                child: Text(dateFormat.format(_date)),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: _start,
                      );
                      if (picked == null) return;
                      setState(() {
                        _start = picked;
                        if (_toMinutes(_end) <= _toMinutes(_start)) {
                          final endMinutes =
                              _start.hour * 60 + _start.minute + 60;
                          _end = TimeOfDay(
                            hour: (endMinutes ~/ 60) % 24,
                            minute: endMinutes % 60,
                          );
                        }
                      });
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: 'Start'),
                      child: Text(_start.format(context)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: _end,
                      );
                      if (picked != null) setState(() => _end = picked);
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: 'End'),
                      child: Text(_end.format(context)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    try {
                      context.read<NodeCubit>().setScheduleBlock(
                            widget.nodeId,
                            _startDateTime,
                            _endDateTime,
                          );
                    } catch (_) {}
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Follow-up scheduled for ${dateFormat.format(_date)} '
                          'at ${_start.format(context)}',
                        ),
                      ),
                    );
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static int _toMinutes(TimeOfDay time) => time.hour * 60 + time.minute;
}
