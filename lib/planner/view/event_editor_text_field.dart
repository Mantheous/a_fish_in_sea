import 'package:flutter/material.dart';

/// Imported text stays selectable while the feed owns its contents.
class EventEditorTextField extends StatelessWidget {
  const EventEditorTextField({
    super.key,
    required this.controller,
    required this.label,
    required this.sourceOwned,
    this.autofocus = false,
    this.maxLines = 1,
  });

  final TextEditingController controller;
  final String label;
  final bool sourceOwned;
  final bool autofocus;
  final int maxLines;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    readOnly: sourceOwned,
    autofocus: autofocus && !sourceOwned,
    maxLines: maxLines,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      helperText: sourceOwned && label == 'Title'
          ? 'Title, notes, and location update from the class feed.'
          : null,
    ),
  );
}
