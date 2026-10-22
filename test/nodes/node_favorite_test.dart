import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/view/nodes_page.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

import '../goldens/golden_app.dart';

class MockStorage extends Mock implements Storage {}

final _day = DateTime(2026, 10, 12, 9);

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  group('favorite cubit', () {
    test('setFavorite toggles and no-ops on unknown ids', () {
      final cubit = NodeCubit();
      addTearDown(cubit.close);
      cubit.emitSilent([
        Node(id: 'a', title: 'Alpha', createdAt: _day),
      ]);
      expect(cubit.favorites, isEmpty);
      cubit.setFavorite('missing', true);
      expect(cubit.state.single.isFavorite, isFalse);
      cubit.setFavorite('a', true);
      expect(cubit.byId('a')!.isFavorite, isTrue);
      expect(cubit.favorites.map((n) => n.id), ['a']);
      cubit.toggleFavorite('a');
      expect(cubit.byId('a')!.isFavorite, isFalse);
      expect(cubit.favorites, isEmpty);
    });

    test('duplicateSubtree keeps the star', () {
      final cubit = NodeCubit();
      addTearDown(cubit.close);
      cubit.emitSilent([
        Node(id: 'a', title: 'Alpha', createdAt: _day, isFavorite: true),
      ]);
      expect(cubit.duplicateSubtree('a', idSuffix: 't'), isNull);
      final copy = cubit.state.firstWhere((n) => n.id != 'a');
      expect(copy.isFavorite, isTrue);
    });
  });

  group('NodesPage favorites filter', () {
    testWidgets('star toggle moves a goal in and out of Favorites',
        (tester) async {
      final nodes = NodeCubit();
      addTearDown(nodes.close);
      nodes.emitSilent([
        Node(id: 'a', title: 'Alpha goal', createdAt: _day),
        Node(
          id: 'b',
          title: 'Beta goal',
          createdAt: _day,
          isFavorite: true,
        ),
      ]);
      await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider.value(value: nodes),
          BlocProvider(create: (_) => TransactionsCubit()),
          BlocProvider(create: (_) => CalendarCubit()),
          BlocProvider(create: (_) => UndoCubit()),
        ],
        child: const MaterialApp(home: NodesPage()),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Favorites'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Beta goal'), findsOneWidget);
      expect(find.text('Alpha goal'), findsNothing);

      // The tile star button unstars in place.
      await tester.tap(find.byTooltip('Unstar'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(nodes.byId('b')!.isFavorite, isFalse);
      expect(find.textContaining('No favorite goals yet.'), findsOneWidget);
    });
  });

  group('HomePage favorite goals', () {
    testWidgets('starred goals show in the Favorite goals section',
        (tester) async {
      final engine = await pumpGoldenPage(tester, const HomePage());
      await tester.runAsync(() async {
        engine.nodes.emitSilent([
          Node(id: 'a', title: 'Alpha goal', createdAt: _day),
          Node(
            id: 'b',
            title: 'Beta goal',
            createdAt: _day,
            isFavorite: true,
          ),
        ]);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
      });
      expect(tester.takeException(), isNull);
      expect(find.text('Favorite goals'), findsOneWidget);
      expect(find.text('Beta goal'), findsWidgets);
      // The empty hint is gone once a favorite exists.
      expect(find.textContaining('star a goal'), findsNothing);
    });
  });
}
