import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../goldens/golden_app.dart';

/// The Toggl-style record badge on calendar tiles: it must render on a
/// timed tile in week view and toggle the event timer on tap WITHOUT
/// opening the detail drawer (the tap is suppressed).
void main() {
  PlannerEvent nineToTen(String id) {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, 9);
    return PlannerEvent(
      id: id,
      subject: 'Tile track $id',
      start: start,
      end: start.add(const Duration(hours: 1)),
    );
  }

  CalendarCubit calendarOf(WidgetTester tester) =>
      BlocProvider.of<CalendarCubit>(
        tester.element(find.byType(CalendarPage)),
      );

  testWidgets('week tile shows record badge and toggles timer on tap',
      (tester) async {
    await pumpGoldenPage(tester, const CalendarPage());
    final calendar = calendarOf(tester);
    calendar.addEvent(nineToTen('e1'));
    // Two frames: the first rebuilds the calendar, the second flushes
    // SfCalendar's internal appointment layout pass.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    final play = find.byTooltip('Start recording');
    expect(play, findsOneWidget);

    await tester.tap(play);
    await tester.pump(const Duration(milliseconds: 200));

    expect(calendar.byId('e1')?.isTracking, isTrue);
    expect(find.byTooltip('Stop recording'), findsOneWidget);
    // The suppress-trick worked: no detail drawer opened.
    expect(find.text('Event details'), findsNothing);

    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pump(const Duration(milliseconds: 200));

    final done = calendar.byId('e1')!;
    expect(done.isTracking, isFalse);
    expect(done.hasReported, isTrue);
    expect(find.byTooltip('Start recording'), findsOneWidget);
  });
}
