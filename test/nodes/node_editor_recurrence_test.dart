import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/model/node_recurrence.dart';
import 'package:a_fish_in_sea/nodes/service/node_editor_recurrence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final previous = NodeRecurrence(
    frequency: TimeScale.custom,
    customPeriodDays: 14,
    dayOfMonth: 23,
    dayOfWeek: DateTime.friday,
    endDate: DateTime(2027, 12, 31),
  );

  test(
    'frequency and end date edits preserve settings the editor cannot edit',
    () {
      final saved = recurrenceAfterEditorSave(
        previous: previous,
        enabled: true,
        frequency: TimeScale.weekly,
        endDate: DateTime(2027, 6, 1),
      );
      expect(
        saved,
        previous.copyWith(
          frequency: TimeScale.weekly,
          endDate: DateTime(2027, 6, 1),
        ),
      );
      expect(
        recurrenceAfterEditorSave(
          previous: saved,
          enabled: true,
          frequency: TimeScale.weekly,
          endDate: null,
        ),
        saved!.copyWith(clearEndDate: true),
      );
    },
  );

  test('disabling repeats clears recurrence', () {
    expect(
      recurrenceAfterEditorSave(
        previous: previous,
        enabled: false,
        frequency: previous.frequency,
        endDate: previous.endDate,
      ),
      isNull,
    );
  });

  test('new repeats use the selected frequency and end date', () {
    expect(
      recurrenceAfterEditorSave(
        previous: null,
        enabled: true,
        frequency: TimeScale.monthly,
        endDate: previous.endDate,
      ),
      NodeRecurrence(frequency: TimeScale.monthly, endDate: previous.endDate),
    );
  });
}
