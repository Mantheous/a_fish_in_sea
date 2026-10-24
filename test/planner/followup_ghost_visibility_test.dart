import 'package:a_fish_in_sea/planner/bloc/calendar_draft_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/calendar_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

import '../goldens/golden_app.dart';

/// Requests a draft before CalendarPage mounts, matching the real
/// "schedule follow-up" flow: the finish sheet fills the draft cubit and
/// navigation creates the calendar page with the seed already pending.
class _PendingDraftPage extends StatefulWidget {
  const _PendingDraftPage({required this.seed});

  final PlannerEvent seed;

  @override
  State<_PendingDraftPage> createState() => _PendingDraftPageState();
}

class _PendingDraftPageState extends State<_PendingDraftPage> {
  @override
  void initState() {
    super.initState();
    context.read<CalendarDraftCubit>().requestDraft(widget.seed);
  }

  @override
  Widget build(BuildContext context) => const CalendarPage();
}

Finder _handle(String label) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == label,
);

void main() {
  testWidgets('a pending follow-up ghost paints on the first calendar layout', (
    tester,
  ) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, 15, 15);
    final seed = PlannerEvent(
      id: calendarDraftEventId,
      subject: 'Follow up',
      start: start,
      end: start.add(const Duration(hours: 1)),
      taskId: 'node:1',
    );

    await pumpGoldenPage(tester, _PendingDraftPage(seed: seed));

    // The ghost used to be added through an incremental data-source event
    // after the first layout, so Syncfusion kept the appointment in the
    // source but never painted a tile for it.
    final tile = find.byKey(const ValueKey('tile:$calendarDraftEventId'));
    expect(tile, findsOneWidget);
    expect(tester.getSize(tile).width, greaterThan(0));
    expect(tester.getSize(tile).height, greaterThan(0));

    final calendar = tester.widget<SfCalendar>(
      find.byKey(const Key('plan-calendar')),
    );
    expect(calendar.controller?.displayDate, start);
    // The ghost is adjustable without tapping it first; both resize circles
    // are part of its first paint.
    expect(_handle('Drag to change start time'), findsOneWidget);
    expect(_handle('Drag to change end time'), findsOneWidget);
    // The create panel explains the ghost that is now actually on screen.
    expect(find.textContaining('Ghost preview'), findsOneWidget);
  });
}
