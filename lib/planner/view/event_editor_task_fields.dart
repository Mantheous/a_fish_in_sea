import 'package:flutter/material.dart';

class EventEditorTaskFields extends StatelessWidget {
  final bool isTask;
  final bool done;
  final ValueChanged<bool> onTaskChanged;
  final ValueChanged<bool> onDoneChanged;

  const EventEditorTaskFields({
    super.key,
    required this.isTask,
    required this.done,
    required this.onTaskChanged,
    required this.onDoneChanged,
  });

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Task'),
        subtitle: const Text(
          'Tasks can be marked complete and show in the Tasks list',
        ),
        value: isTask,
        onChanged: onTaskChanged,
      ),
      if (isTask)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Completed'),
          value: done,
          onChanged: (value) => onDoneChanged(value ?? false),
        ),
    ],
  );
}
