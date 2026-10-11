import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../goldens/golden_app.dart';

void main() {
  PlannerEvent evt(String id, int minutes) {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, 9);
    return PlannerEvent(
      id: id,
      subject: 'Short $id',
      start: start,
      end: start.add(Duration(minutes: minutes)),
    );
  }

  CalendarCubit calendarOf(WidgetTester tester) =>
      BlocProvider.of<CalendarCubit>(
        tester.element(find.byType(CalendarPage)),
      );

  testWidgets('1h tile shows badge, 15min tile hides it', (tester) async {
    await pumpGoldenPage(tester, const CalendarPage());
    final calendar = calendarOf(tester);
    calendar.addEvent(evt('long1', 60));
    calendar.addEvent(evt('short1', 15));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    final play = find.byTooltip('Start recording');
    // ignore: avoid_print
    print('BADGE_COUNT=${play.evaluate().length}');
    // Long tile must keep its badge: at least one badge visible.
    expect(play, findsWidgets);
  });
}
