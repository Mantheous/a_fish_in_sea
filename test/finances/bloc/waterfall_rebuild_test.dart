import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

class TestPlaidCubit extends PlaidCubit {
  void update({double? balance, PlaidConnectionStatus? status}) =>
      emit(state.copyWith(currentBalance: balance, status: status));
}

class CountingWaterfallCubit extends WaterfallCubit {
  CountingWaterfallCubit({
    required super.nodeCubit,
    required super.transactionsCubit,
    required super.plaidCubit,
  });

  int rebuildCount = 0;

  @override
  void rebuild() {
    rebuildCount++;
    super.rebuild();
  }
}

void main() {
  late NodeCubit nodes;
  late TransactionsCubit transactions;
  late TestPlaidCubit plaid;
  late CountingWaterfallCubit waterfall;

  Node node(String id, {bool hasMoney = false, bool repeats = false}) => Node(
    id: id,
    title: id,
    createdAt: DateTime(2026, 1, 1),
    schedule: ScheduleFacet(due: DateTime.now()),
    money: hasMoney ? const MoneyFacet(targetAmount: 10) : null,
    recurrence: repeats
        ? const NodeRecurrence(frequency: TimeScale.monthly)
        : null,
  );

  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    nodes = NodeCubit();
    transactions = TransactionsCubit();
    plaid = TestPlaidCubit();
    waterfall = CountingWaterfallCubit(
      nodeCubit: nodes,
      transactionsCubit: transactions,
      plaidCubit: plaid,
    );
  });

  tearDown(() async {
    await waterfall.close();
    await nodes.close();
    await transactions.close();
    await plaid.close();
  });

  test('task scheduling skips the finance rebuild entirely', () async {
    final money = node('rent', hasMoney: true, repeats: true);
    final task = node('task');
    nodes.emitSilent([money, task]);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final before = waterfall.rebuildCount;
    final rows = waterfall.state.rows;

    nodes.emitSilent([
      ...nodes.state.where((n) => n.id != task.id),
      task.copyWith(schedule: ScheduleFacet(due: DateTime(2027, 2, 2))),
    ]);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(waterfall.rebuildCount, before);
    expect(identical(waterfall.state.rows, rows), isTrue);
  });

  test('first unrelated node emission also skips rebuilding', () async {
    final before = waterfall.rebuildCount;
    nodes.emitSilent([node('task')]);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(waterfall.rebuildCount, before);
  });

  test(
    'money addition, schedule edit, and removal rebuild the ledger',
    () async {
      var money = node('bill', hasMoney: true);
      nodes.emitSilent([money]);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(waterfall.state.rows.single.sourceId, money.id);

      money = money.copyWith(
        schedule: ScheduleFacet(due: DateTime(2027, 2, 2)),
      );
      nodes.emitSilent([money]);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(waterfall.state.rows.single.date, DateTime(2027, 2, 2));

      nodes.emitSilent([money.copyWith(clearMoney: true)]);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(waterfall.state.rows, isEmpty);
    },
  );

  test(
    'bank status changes skip rebuilding but balance updates rebuild',
    () async {
      final before = waterfall.rebuildCount;
      plaid.update(status: PlaidConnectionStatus.connecting);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(waterfall.rebuildCount, before);

      plaid.update(balance: 123);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(waterfall.rebuildCount, before + 1);
      expect(waterfall.state.startingBalance, 123);

      plaid.update(status: PlaidConnectionStatus.connected);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(waterfall.rebuildCount, before + 1);
    },
  );

  test(
    'unchanged rebuild emits no derived state or persistence write',
    () async {
      nodes.emitSilent([node('bill', hasMoney: true)]);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final emitted = <WaterfallState>[];
      final subscription = waterfall.stream.listen(emitted.add);
      final before = waterfall.state;
      clearInteractions(HydratedBloc.storage as MockStorage);

      waterfall.rebuild();
      await Future<void>.delayed(Duration.zero);

      expect(waterfall.state, before);
      expect(emitted, isEmpty);
      verifyNever(() => HydratedBloc.storage.write(any(), any()));
      await subscription.cancel();
    },
  );
}
