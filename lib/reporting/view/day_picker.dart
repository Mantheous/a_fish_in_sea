import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../common/time/local_date.dart';
import '../reporting_logic.dart';

final _reviewDayFormat = DateFormat('EEE, MMM d');
final _reviewDayYearFormat = DateFormat('EEE, MMM d, yyyy');

class DayPicker extends StatelessWidget {
  final DateTime day;
  final ValueChanged<DateTime> onChanged;

  const DayPicker({super.key, required this.day, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final isToday = isSameDay(day, today);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => onChanged(shiftLocalDay(day, -1)),
          ),
          Expanded(
            child: InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: day,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                );
                if (picked != null) onChanged(picked);
              },
              child: Text(
                isToday
                    ? 'Today · ${_reviewDayFormat.format(day)}'
                    : _reviewDayYearFormat.format(day),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: isToday ? null : () => onChanged(shiftLocalDay(day, 1)),
          ),
        ],
      ),
    );
  }
}
