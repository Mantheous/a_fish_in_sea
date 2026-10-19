import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/event_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../goldens/golden_app.dart';

void main() {
  testWidgets(
    'delete stays reachable while editing and remains deleted after Undo expires',
    (tester) async {
      final start = DateTime(2026, 10, 20, 9);
      final event = PlannerEvent(
        id: 'local-event',
        subject: 'Weekly planning',
        start: start,
        end: start.add(const Duration(hours: 1)),
      );

      await pumpGoldenPage(
        tester,
        EventEditorForm(existing: event, title: 'Edit event'),
      );
      final calendar = BlocProvider.of<CalendarCubit>(
        tester.element(find.byType(EventEditorForm)),
      );
      calendar.addEvent(event);
      await tester.pumpAndSettle();

      final delete = find.text('Delete');
      final initialPosition = tester.getTopLeft(delete);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -900),
      );
      await tester.pumpAndSettle();
      expect(delete, findsOneWidget);
      expect(tester.getTopLeft(delete).dy, closeTo(initialPosition.dy, 1));

      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(calendar.byId(event.id), isNull);
      expect(find.text('Event deleted'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('Undo'), findsNothing);
      expect(calendar.byId(event.id), isNull);
    },
  );

  testWidgets(
    'opening the next editor retires the previous delete undo bar',
    (tester) async {
      final start = DateTime(2026, 10, 20, 9);
      PlannerEvent event(String id, String subject) => PlannerEvent(
            id: id,
            subject: subject,
            start: start,
            end: start.add(const Duration(hours: 1)),
          );
      final first = event('event-a', 'First');
      final second = event('event-b', 'Second');

      await pumpGoldenPage(
        tester,
        _TwoEditorHost(first: first, second: second),
      );
      final calendar = BlocProvider.of<CalendarCubit>(
        tester.element(find.byType(EventEditorForm)),
      );
      calendar.addEvent(first);
      calendar.addEvent(second);
      await tester.pumpAndSettle();

      // Delete the first event; the host advances to the second editor,
      // mirroring a rapid successive delete (g1, then g2 in refs #14).
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      // The first event stays deleted and no stale undo bar survives above
      // the second editor: a mis-tap aimed at Delete cannot resurrect it,
      // and Delete stays hittable for the next event.
      expect(calendar.byId(first.id), isNull);
      expect(find.text('Event deleted'), findsNothing);
      expect(find.text('Delete'), findsOneWidget);

      // The next delete still works and still offers its own undo bar,
      // since no further editor opens after it.
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(calendar.byId(second.id), isNull);
      expect(find.text('Event deleted'), findsOneWidget);
    },
  );
}

/// Advances from an editor for [first] to an editor for [second] when the
/// first editor finishes, mirroring rapid successive deletes.
class _TwoEditorHost extends StatefulWidget {
  final PlannerEvent first;
  final PlannerEvent second;

  const _TwoEditorHost({required this.first, required this.second});

  @override
  State<_TwoEditorHost> createState() => _TwoEditorHostState();
}

class _TwoEditorHostState extends State<_TwoEditorHost> {
  var _index = 0;

  @override
  Widget build(BuildContext context) {
    if (_index > 1) return const Text('done');
    final event = _index == 0 ? widget.first : widget.second;
    return EventEditorForm(
      key: ValueKey('edit:${event.id}'),
      existing: event,
      title: 'Edit event',
      onFinished: () => setState(() => _index++),
    );
  }
}
