import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/event_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_app.dart';

Future<void> linkAndEditRecurringEvent(WidgetTester tester, BuildContext context,
    {bool task = false, bool golden = false}) async {
  final start = DateTime(2026, 11, 2, 9);
  final event = PlannerEvent(id: 'google', subject: 'Literature lecture', start: start,
    end: start.add(const Duration(hours: 1)), feedId: 'google',
    sourceUid: 'occurrence', seriesId: 'master', isTask: task);
  context.read<FeedCubit>().addFeed(const Feed(id: 'google', name: 'Google',
    url: '', kind: FeedKind.google, calendarId: 'primary'));
  context.read<CalendarCubit>().addEvent(event);
  context.read<NodeCubit>().addNode(Node(id: 'class', title: 'CMLIT 202',
    createdAt: start, classFacet: const ClassFacet()));
  showEventDetail(context, event: event);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  await tester.ensureVisible(find.text('Assign to goal'));
  await tester.tap(find.text('Assign to goal'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('CMLIT 202').last);
  await tester.pumpAndSettle();
  expect(context.read<NodeCubit>().state.any((n) => n.parentIds.contains('class')), isTrue);
  await tester.ensureVisible(find.text('Edit'));
  if (golden) await expectLater(find.byType(MaterialApp),
    matchesGoldenFile('recurring_event_editor.png'));
  await tester.tap(find.text('Edit'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  expect(find.text('Edit event'), findsOneWidget);
}

void main() {
  for (final task in [false, true]) {
    testWidgets('repeating Google detail links and edits (task: $task)', (tester) async {
      await pumpGoldenPage(tester, const SizedBox());
      await linkAndEditRecurringEvent(tester, tester.element(find.byType(Scaffold).first),
        task: task, golden: !task);
    });
  }
}
