import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/nodes_page.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

class MockStorage extends Mock implements Storage {}

/// Covers the issue #53 user flow: starring a goal pins it under the
/// Favorites filter on the Nodes page, and unstarring removes it again.
/// Pure widgets (no server), like transaction_reassign_test.
///
/// Run headless:
///   patrol test --device chrome --web-headless \
///     --target patrol_test/favorite_goals_test.dart \
///     --dart-define=SERVER_URL=http://127.0.0.1:8000
void main() {
  patrolTest('star toggle moves a goal in and out of Favorites', ($) async {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    final nodes = NodeCubit();
    addTearDown(nodes.close);
    final day = DateTime(2026, 10, 12, 9);
    nodes.emitSilent([
      Node(id: 'a', title: 'Alpha goal', createdAt: day),
      Node(id: 'b', title: 'Beta goal', createdAt: day, isFavorite: true),
    ]);

    await $.pumpWidgetAndSettle(
      MultiBlocProvider(
        providers: [
          BlocProvider<NodeCubit>.value(value: nodes),
          BlocProvider(create: (_) => TransactionsCubit()),
          BlocProvider(create: (_) => CalendarCubit()),
          BlocProvider(create: (_) => UndoCubit()),
        ],
        child: const MaterialApp(home: NodesPage()),
      ),
    );

    // Favorites shows only the starred goal.
    await $('Favorites').tap();
    await $.pumpAndSettle();
    expect($('Beta goal').visible, true);
    expect($('Alpha goal').visible, false);

    // The tile star button unstars in place.
    await $(Icons.star).tap();
    await $.pumpAndSettle();
    expect(nodes.byId('b')!.isFavorite, isFalse);
    expect($('Beta goal').visible, false);
  });
}
