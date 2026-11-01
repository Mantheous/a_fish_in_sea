import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:flutter_test/flutter_test.dart';

import '../planner/calendar_alignment_scenario.dart';
import 'golden_app.dart';

void main() {
  // TZ=America/Denver exercises both daylight-saving clock changes.
  for (final day in [DateTime(2026, 3, 8), DateTime(2026, 11, 1)]) {
    for (final start in [0.0, 6.0, 6.25]) {
      for (final view in ['Day', 'Week']) {
        testWidgets('$day $view aligns reports from $start', (tester) async {
          await pumpGoldenPage(
            tester,
            CalendarPage(
              initialDisplayDate: day,
              showCurrentTimeIndicator: false,
            ),
          );
          await verifyCalendarAlignment(
            tester,
            day,
            start,
            view,
            golden: day.month == 11 && start == 6 && view == 'Week'
                ? '../goldens/calendar_grid_alignment.week.png'
                : null,
          );
        });
      }
    }
  }
}
