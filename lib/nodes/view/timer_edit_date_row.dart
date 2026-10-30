part of 'timer_edit_sheet.dart';

class _DateRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onPick;

  const _DateRow({
    required this.label,
    required this.value,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPick,
      child: InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Text(value),
      ),
    );
  }
}
