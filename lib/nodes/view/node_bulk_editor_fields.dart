import 'package:flutter/material.dart';

/// Compact "apply this section" switch used throughout the bulk editor.
class BulkToggleTile extends StatelessWidget {
  const BulkToggleTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// Keep / On / Off selector for flags whose current value must not change
/// unless the user says so.
class BulkTriStateField extends StatelessWidget {
  const BulkTriStateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool? value;
  final ValueChanged<bool?>? onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<bool?>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: const [
        DropdownMenuItem(value: null, child: Text('Keep unchanged')),
        DropdownMenuItem(value: true, child: Text('On')),
        DropdownMenuItem(value: false, child: Text('Off')),
      ],
      onChanged: onChanged,
    );
  }
}

Widget bulkSectionTitle(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.only(bottom: 4),
  child: Text(
    text,
    style: Theme.of(
      context,
    ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
  ),
);
