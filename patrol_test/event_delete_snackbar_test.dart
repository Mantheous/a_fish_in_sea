import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/view/event_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import '../test/goldens/golden_app.dart';

/// Successive deletes through the real event editor (refs #14).
///
/// A previous delete's undo bar draws above the sheet: opening the next
/// editor must retire it, so a mis-tap aimed at Delete cannot resurrect
/// the earlier event and the bar never covers the next editor's actions.
///
/// Run headless (no server needed — pure widgets, like smoke_test):
///   patrol test --device chrome --web-headless \
///     --target patrol_test/event_delete_snackbar_test.dart \
///     --dart-define=SERVER_URL=http://127.0.0.1:8000
void main() {
  patrolTest('successive deletes retire the stale undo bar', ($) async {
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
      $.tester,
      _TwoEditorHost(first: first, second: second),
    );
    final calendar = BlocProvider.of<CalendarCubit>(
      $.tester.element(find.byType(EventEditorForm)),
    );
    calendar.addEvent(first);
    calendar.addEvent(second);
    await $.pumpAndSettle();

    await $('Delete').tap();
    await $.pumpAndSettle();

    expect(calendar.byId(first.id), isNull);
    expect(find.text('Event deleted'), findsNothing);
    expect($('Delete').visible, true);

    await $('Delete').tap();
    await $.pumpAndSettle();
    expect(calendar.byId(second.id), isNull);
    expect($('Event deleted').visible, true);
  });
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
