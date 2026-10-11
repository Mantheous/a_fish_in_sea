import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/finances/model/granularity.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/view/waterfall_ledger_page.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

/// The waterfall view, driven end-to-end.
///
/// These are the regression tests for the bug where
/// `monthlyThresholdDays` / `weeklyThresholdDays` were persisted,
/// editable from the tune dialog and never read by any computation — the
/// spec's headline "dynamic granularity by distance" existed only as
/// configuration. They assert the values actually reach the rendered
/// list, and that collapsing never removes a row from the model.
void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  final today = DateTime.now();
  final todayOnly = DateTime(today.year, today.month, today.day);

  Node moneyNode(String id, DateTime due, double amount) => Node(
        id: id,
        title: id,
        createdAt: DateTime(2026, 1, 1),
        schedule: ScheduleFacet(due: due),
        money: MoneyFacet(
          targetAmount: amount,
          direction: MoneyDirection.spend,
        ),
      );

  /// Pumps the page and returns the built waterfall cubit so a test can
  /// drive thresholds / view scale directly.
  Future<WaterfallCubit> pumpLedger(
    WidgetTester tester, {
    required List<Node> nodes,
    bool expand = false,
  }) async {
    final nodeCubit = NodeCubit();
    final transactionsCubit = TransactionsCubit();
    final plaidCubit = PlaidCubit();
    final waterfallCubit = WaterfallCubit(
      nodeCubit: nodeCubit,
      transactionsCubit: transactionsCubit,
      plaidCubit: plaidCubit,
    );
    nodeCubit.emitSilent(nodes);

    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider.value(value: nodeCubit),
        BlocProvider.value(value: transactionsCubit),
        BlocProvider.value(value: plaidCubit),
        BlocProvider.value(value: waterfallCubit),
        BlocProvider(create: (_) => UndoCubit()),
      ],
      child: const MaterialApp(home: WaterfallLedgerPage()),
    ));
    await tester.pumpAndSettle();
    if (expand) {
      // Expand every collapsible bucket so row-level assertions are
      // checking the model, not the collapsed summary.
      var expanded = 0;
      while (true) {
        final icons = find.byIcon(Icons.expand_more);
        if (!icons.evaluate().isNotEmpty) break;
        await tester.tap(icons.first);
        await tester.pumpAndSettle();
        if (++expanded > 50) break;
      }
    }
    return waterfallCubit;
  }

  testWidgets('renders bucket headers for multi-row months', (tester) async {
    await pumpLedger(
      tester,
      expand: true,
      nodes: [
        // Both far enough out to be monthly, same month → one bucket.
        moneyNode('a', DateTime(2027, 1, 3), 10),
        moneyNode('b', DateTime(2027, 1, 20), 20),
      ],
    );

    // The month header is present and the two rows still render.
    expect(find.text('January 2027'), findsOneWidget);
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
    // Header reports the grouping it is doing.
    expect(find.text('2 entries'), findsOneWidget);
  });

  testWidgets('near rows bucket by day, not by month', (tester) async {
    await pumpLedger(
      tester,
      expand: true,
      nodes: [
        moneyNode('today-row', todayOnly, 5),
        moneyNode('tomorrow-row',
            todayOnly.add(const Duration(days: 1)), 6),
      ],
    );

    // Two distinct daily buckets → two day headers, no month grouping.
    expect(find.textContaining('Today'), findsWidgets);
    expect(find.text('today-row'), findsOneWidget);
    expect(find.text('tomorrow-row'), findsOneWidget);
  });

  testWidgets('collapsing hides rows but keeps them in the model',
      (tester) async {
    final cubit = await pumpLedger(
      tester,
      expand: true,
      nodes: [
        moneyNode('a', DateTime(2027, 1, 3), 10),
        moneyNode('b', DateTime(2027, 1, 20), 20),
      ],
    );
    expect(find.text('a'), findsOneWidget);
    expect(cubit.state.buckets.single.entries.length, 2);

    // Collapse the bucket.
    await tester.tap(find.text('January 2027'));
    await tester.pumpAndSettle();

    // The rows are gone from the screen…
    expect(find.text('a'), findsNothing);
    expect(find.text('b'), findsNothing);
    // …but the bucket still holds them, so the underlying model kept the
    // granular data. This is the spec's rule.
    expect(cubit.state.buckets.single.entries.length, 2);
    expect(cubit.state.rows.length, 2);

    // Expanding brings them back.
    await tester.tap(find.byIcon(Icons.expand_more).first);
    await tester.pumpAndSettle();
    expect(find.text('a'), findsOneWidget);
  });

  testWidgets('widening the thresholds changes the rendered granularity',
      (tester) async {
    final cubit = await pumpLedger(
      tester,
      expand: true,
      nodes: [moneyNode('mid', todayOnly.add(const Duration(days: 20)), 10)],
    );
    // Default (60/7): 20 days out is weekly.
    expect(cubit.state.buckets.single.granularity,
        DisplayGranularity.weekly);

    cubit.setWaterfallThresholds(
      monthlyThresholdDays: 365,
      weeklyThresholdDays: 30,
    );
    await tester.pumpAndSettle();
    // Same row, now inside the daily window.
    expect(cubit.state.buckets.single.granularity,
        DisplayGranularity.daily);
  });

  testWidgets('a fixed view scale buckets everything at that scale',
      (tester) async {
    final cubit = await pumpLedger(
      tester,
      expand: true,
      nodes: [
        moneyNode('near', todayOnly, 10),
        moneyNode('far', DateTime(2027, 1, 3), 20),
      ],
    );
    cubit.setViewScale(TimeScale.daily);
    await tester.pumpAndSettle();
    expect(
        cubit.state.buckets.every((b) => b.granularity == DisplayGranularity.daily),
        isTrue);
  });

  testWidgets('the entry summary counts buckets when they differ from rows',
      (tester) async {
    await pumpLedger(
      tester,
      expand: true,
      nodes: [
        moneyNode('a', DateTime(2027, 1, 3), 10),
        moneyNode('b', DateTime(2027, 1, 20), 20),
      ],
    );
    // 2 rows in 1 bucket, so the summary mentions both.
    expect(find.textContaining('2 entries'), findsWidgets);
    expect(find.textContaining('1 bucket'), findsOneWidget);
  });
}
