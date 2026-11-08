import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../planner/bloc/settings_cubit.dart';
import '../bloc/places_cubit.dart';
import '../bloc/reporting_cubit.dart';
import '../model/reported_entry.dart';
import 'time_range_dial.dart';

Future<void> showReportedEditor(
  BuildContext context, {
  required DateTime day,
  required ReportedEntry entry,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: _ReportedEditorSheet(day: day, entry: entry),
    ),
  );
}

class _ReportedEditorSheet extends StatefulWidget {
  final DateTime day;
  final ReportedEntry entry;

  const _ReportedEditorSheet({required this.day, required this.entry});

  @override
  State<_ReportedEditorSheet> createState() => _ReportedEditorSheetState();
}

class _ReportedEditorSheetState extends State<_ReportedEditorSheet> {
  late final TextEditingController _title;
  late ReportStatus _status;
  late TimeOfDay _start;
  late TimeOfDay _end;
  late String? _placeId;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.entry.title);
    _status = widget.entry.status;
    _start = TimeOfDay.fromDateTime(widget.entry.start);
    _end = TimeOfDay.fromDateTime(widget.entry.end);
    _placeId = widget.entry.placeId;
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  DateTime _at(DateTime original, TimeOfDay time) {
    // Title/status/place edits must retain the exact stored timestamp,
    // including its date and sub-minute precision.
    if (TimeOfDay.fromDateTime(original) == time) return original;
    return DateTime(
      original.year,
      original.month,
      original.day,
      time.hour,
      time.minute,
    );
  }

  @override
  Widget build(BuildContext context) {
    final places = context.watch<PlacesCubit>().state;
    var snap = 5;
    try {
      snap = context.read<SettingsCubit>().state.snapMinutes;
    } catch (_) {}
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Edit reported entry',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Center(
              child: TimeRangeDial(
                start: _start,
                end: _end,
                snapMinutes: snap,
                onStartChanged: (v) => setState(() => _start = v),
                onEndChanged: (v) => setState(() => _end = v),
              ),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _title,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ReportStatus>(
              initialValue: _status,
              decoration: const InputDecoration(
                labelText: 'Marked as',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: ReportStatus.attended,
                  child: Text('Attended'),
                ),
                DropdownMenuItem(
                  value: ReportStatus.partial,
                  child: Text('Partial'),
                ),
                DropdownMenuItem(
                  value: ReportStatus.missed,
                  child: Text('Missed'),
                ),
                DropdownMenuItem(
                  value: ReportStatus.extra,
                  child: Text('Extra'),
                ),
              ],
              onChanged: (v) =>
                  setState(() => _status = v ?? ReportStatus.attended),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _placeId,
              decoration: const InputDecoration(
                labelText: 'Place',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('No place')),
                for (final place in places)
                  DropdownMenuItem(value: place.id, child: Text(place.name)),
              ],
              onChanged: (v) => setState(() => _placeId = v),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _TimeField(
                    label: 'Start',
                    value: _start,
                    onChanged: (v) => setState(() => _start = v),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _TimeField(
                    label: 'End',
                    value: _end,
                    onChanged: (v) => setState(() => _end = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    context.read<ReportingCubit>().deleteEntry(
                      widget.day,
                      widget.entry.id,
                    );
                    Navigator.of(context).pop();
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  child: const Text('Delete'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    var end = _at(widget.entry.end, _end);
                    final start = _at(widget.entry.start, _start);
                    if (!end.isAfter(start)) {
                      // Calendar construction keeps the selected wall time
                      // across month/year and daylight-saving boundaries.
                      end = DateTime(
                        start.year,
                        start.month,
                        start.day + 1,
                        end.hour,
                        end.minute,
                        end.second,
                        end.millisecond,
                        end.microsecond,
                      );
                    }
                    context.read<ReportingCubit>().upsertEntry(
                      widget.day,
                      widget.entry.copyWith(
                        title: _title.text.trim().isEmpty
                            ? widget.entry.title
                            : _title.text.trim(),
                        placeId: _placeId,
                        clearPlaceId: _placeId == null,
                        start: start,
                        end: end,
                        status: _status,
                      ),
                    );
                    Navigator.of(context).pop();
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
}

class _TimeField extends StatelessWidget {
  final String label;
  final TimeOfDay value;
  final ValueChanged<TimeOfDay> onChanged;

  const _TimeField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(labelText: label),
      child: InkWell(
        onTap: () async {
          final picked = await showTimePicker(
            context: context,
            initialTime: value,
          );
          if (picked != null) onChanged(picked);
        },
        child: Text(value.format(context)),
      ),
    );
  }
}
