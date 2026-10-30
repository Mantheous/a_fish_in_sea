import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:flutter_test/flutter_test.dart';

import '../planner/dst_drag_scenario.dart';
import 'golden_app.dart';

void main() {
  for (final day in [DateTime(2026, 3, 8), DateTime(2026, 11, 1)]) {
    for (final view in ['Day', 'Week']) {
      testWidgets('$view sideways drop on $day stays at 9 AM', (tester) async {
        await pumpGoldenPage(
          tester,
          CalendarPage(
            initialDisplayDate: day,
            showCurrentTimeIndicator: false,
          ),
        );
        final tile = await verifyDstCalendarDrag(tester, day, view: view);
        await expectLater(
          tile,
          matchesGoldenFile('calendar_dst_drag.${day.month}.$view.png'),
        );
      });
    }
  }
}
