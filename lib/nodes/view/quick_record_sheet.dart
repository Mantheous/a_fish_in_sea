import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../common/usage/usage_log.dart';
import '../../planner/bloc/calendar_cubit.dart';
import '../bloc/node_cubit.dart';
import '../service/quick_record.dart';

/// Asks for a name and immediately starts recording a new task.
///
/// One field, one button: the point is to capture something unplanned
/// (a meal, a commute, an errand) while it is happening. The task can be
/// assigned to a goal later from the finish sheet or its task row.
Future<void> showQuickRecordSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => const _QuickRecordSheet(),
  );
}

class _QuickRecordSheet extends StatefulWidget {
  const _QuickRecordSheet();

  @override
  State<_QuickRecordSheet> createState() => _QuickRecordSheetState();
}

class _QuickRecordSheetState extends State<_QuickRecordSheet> {
  final _title = TextEditingController();
  String? _error;
  bool _starting = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _start() {
    if (_starting) return;
    final name = _title.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Name it first.');
      return;
    }
    NodeCubit nodes;
    CalendarCubit calendar;
    try {
      nodes = context.read<NodeCubit>();
      calendar = context.read<CalendarCubit>();
    } catch (_) {
      setState(() => _error = 'Recording is unavailable here.');
      return;
    }
    final result = startQuickRecording(nodes, calendar, name);
    final created = result.node;
    if (result.error != null || created == null) {
      setState(() => _error = result.error ?? 'Could not start recording.');
      return;
    }
    UsageLog.instance.action('recording.quick.start');
    setState(() => _starting = true);
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Recording “${created.title}”'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      // Keep the field above the on-screen keyboard.
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.fiber_manual_record,
                  size: 16,
                  color: Color(0xFFFF5252),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Record something',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Starts the timer now. No date or goal needed — '
              'you can assign it to a goal later.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _start(),
              decoration: InputDecoration(
                labelText: 'What are you doing?',
                hintText: 'Lunch, train to Provo, groceries…',
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.fiber_manual_record, size: 18),
              label: const Text('Start recording'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}
