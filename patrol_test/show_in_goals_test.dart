import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/nodes/view/node_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

class MockStorage extends Mock implements Storage {}

/// "Show in goals" end-to-end: a task's three-dots menu jumps to the goal
/// tree with the task revealed in the All view.
///
/// Run against the live dev API server:
///   patrol test --device chrome --web-headless \
///     --target patrol_test/show_in_goals_test.dart \
///     --dart-define=SERVER_URL=http://127.0.0.1:8000
///
/// Uses a unique email per run so reruns never 409. Leaves one junk
/// account per run on the dev server (same as the other patrol tests).
void main() {
  patrolTest('task menu Show in goals reveals it in the goal tree', ($) async {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    await $.pumpWidgetAndSettle(const MyApp());

    final stamp = DateTime.now().millisecondsSinceEpoch;
    await $(TextField).at(0).enterText('patrol-goals-$stamp@example.com');
    await $(TextField).at(1).enterText('patrol-pass-1');
    await $('Create account').tap();
    await $.pumpAndSettle();

    // Go to Tasks and create one goal via the FAB editor.
    await $(Icons.menu).tap();
    await $.pumpAndSettle();
    await $('Tasks').tap();
    await $.pumpAndSettle();
    await $(FloatingActionButton).tap();
    await $.pumpAndSettle();
    expect($('New node').visible, true);
    final title = 'Patrol goal $stamp';
    await $(TextField).at(0).enterText(title);
    await $('Add').tap();
    await $.pumpAndSettle();
    expect($(title).visible, true);

    // Three-dots menu scoped to the task row (the AppBar has its own
    // more_vert menu, so a bare index would be ambiguous).
    final rowMenu = find.descendant(
      of: find.byType(NodeTile),
      matching: find.byIcon(Icons.more_vert),
    );
    expect(rowMenu, findsOneWidget);
    await $.tester.tap(rowMenu);
    await $.pumpAndSettle();
    await $('Show in goals').tap();
    await $.pumpAndSettle();

    // Landed on Nodes, All tree view, with the task revealed.
    expect($('Nodes').visible, true);
    expect($(title).visible, true);
    final allChip = find.ancestor(
      of: find.text('All'),
      matching: find.byType(ChoiceChip),
    );
    expect(allChip, findsOneWidget);
    expect($.tester.widget<ChoiceChip>(allChip).selected, true);
  });
}
