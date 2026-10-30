import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:a_fish_in_sea/reporting/view/reported_entry_editor.dart';
import 'package:a_fish_in_sea/reporting/view/time_range_dial.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_app.dart';

void main() {
  for (final scenario in ['overnight', 'same day', 'multi day', 'edit end']) {
    testWidgets('$scenario retains endpoint dates when saving', (tester) async {
      final start = DateTime(2026, 12, 31, 23, 0, 12, 34, 56);
      final end = switch (scenario) {
        'same day' || 'edit end' => DateTime(2026, 12, 31, 23, 30),
        'multi day' => DateTime(2027, 1, 2, 1, 0, 45, 67, 89),
        _ => DateTime(2027, 1, 1, 1, 0, 45, 67, 89),
      };
      // The review bucket need not be the endpoint's calendar date.
      final day = DateTime(2027, 1, 1);
      final entry = ReportedEntry(
        id: 'overnight',
        title: 'Late work',
        start: start,
        end: end,
        status: ReportStatus.attended,
        eventId: 'planned',
        tagIds: const ['work'],
      );
      await pumpGoldenPage(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showReportedEditor(context, day: day, entry: entry),
            child: const Text('Edit'),
          ),
        ),
      );
      final reporting = tester
          .element(find.text('Edit'))
          .read<ReportingCubit>();
      reporting.upsertEntry(day, entry);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      if (scenario == 'overnight') {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('reported_entry_editor_test.overnight.png'),
        );
      }
      await tester.enterText(find.byType(TextField), 'Late work renamed');
      if (scenario == 'edit end') {
        // Exercise the dial's shared update path used by both time controls.
        tester
            .widget<TimeRangeDial>(find.byType(TimeRangeDial))
            .onEndChanged(const TimeOfDay(hour: 1, minute: 0));
        await tester.pump();
      }
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final saved = reporting.entriesForDay(day).single;
      expect(saved.title, 'Late work renamed');
      expect(saved.start, start);
      expect(saved.end, scenario == 'edit end' ? DateTime(2027, 1, 1, 1) : end);
      expect(saved.eventId, entry.eventId);
      expect(saved.tagIds, entry.tagIds);
      expect(saved.auto, isFalse);
      expect(reporting.entriesForDay(DateTime(2026, 12, 31)), isEmpty);
    });
  }
}
