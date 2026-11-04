import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:flutter_test/flutter_test.dart';

import '../planner/imported_assignment_scenario.dart';
import 'golden_app.dart';

void main() {
  testWidgets('imported assignment can move, resize and edit', (tester) async {
    await pumpGoldenPage(
      tester,
      CalendarPage(
        initialDisplayDate: DateTime(2030, 1, 1),
        showCurrentTimeIndicator: false,
      ),
    );
    await verifyImportedAssignment(tester, golden: true);
  });
}
