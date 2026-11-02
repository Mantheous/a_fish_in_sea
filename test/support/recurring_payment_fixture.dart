import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/finances/view/rules_and_budgets_page.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _Storage extends Mock implements Storage {}

class RecurringPaymentFixture {
  late NodeCubit nodes;
  late UndoCubit undo;
  late CalendarCubit calendar;
  late WaterfallCubit waterfall;
  late Node template;
  late List<Node> before;
  late String refreshedId;
  late Set<String> refreshedIds;
  late double oldBalance;

  Future<void> pump(WidgetTester tester, {String? notes}) async {
    final storage = _Storage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    nodes = NodeCubit();
    undo = UndoCubit();
    calendar = CalendarCubit();
    final transactions = TransactionsCubit();
    final plaid = PlaidCubit();
    waterfall = WaterfallCubit(
      nodeCubit: nodes,
      transactionsCubit: transactions,
      plaidCubit: plaid,
    );
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      for (final cubit in [
        waterfall,
        nodes,
        undo,
        calendar,
        transactions,
        plaid,
      ]) {
        await cubit.close();
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final now = DateTime.now();
    final start = DateTime(now.year, now.month - 1, 1);
    template = Node(
      id: 'rent',
      title: 'Rent',
      notes: notes,
      createdAt: start,
      schedule: ScheduleFacet(due: start),
      money: const MoneyFacet(targetAmount: 100),
      recurrence: NodeRecurrence(
        frequency: TimeScale.monthly,
        endDate: DateTime(now.year, now.month + 10, 1),
      ),
    );
    nodes.addNode(template);
    nodes.generateInstances(
      templateId: template.id,
      from: start,
      horizon: DateTime(now.year, now.month + 10, 1),
    );
    final copies = nodes.instancesOf(template.id);
    // Use the last future copy for a hand edit back to the inherited amount.
    nodes.updateNode(
      copies.last.copyWith(
        money: copies.last.money!.copyWith(targetAmount: 80),
      ),
    );
    nodes.updateNode(
      nodes.byId(copies.last.id)!.copyWith(money: copies.last.money),
    );
    nodes.updateNode(copies[10].copyWith(title: 'Hand edited rent'));
    nodes.writeNodes(
      upserts: [
        copies[3].copyWith(
          money: copies[3].money!.copyWith(status: MoneyStatus.paid),
        ),
        copies[4].copyWith(
          money: copies[4].money!.copyWith(linkedTransactionIds: ['txn']),
        ),
        copies[5].copyWith(money: copies[5].money!.copyWith(targetAmount: 75)),
        copies[6].withOverride('money.targetAmount'),
        copies[7].copyWith(money: copies[7].money!.copyWith(actualAmount: 20)),
        copies[8].copyWith(status: NodeStatus.done),
        copies[9].copyWith(
          money: copies[9].money!.copyWith(status: MoneyStatus.due),
        ),
      ],
    );
    refreshedId = copies[2].id;
    refreshedIds = {copies[2].id, if (now.day == 1) copies[1].id};
    waterfall.rebuild();
    oldBalance = waterfall.state.rows
        .singleWhere((r) => r.sourceId == refreshedId)
        .runningBalance;
    before = List.of(nodes.state);
    undo.resetHistory();
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider.value(value: nodes),
          BlocProvider.value(value: undo),
          BlocProvider.value(value: calendar),
        ],
        child: MaterialApp(
          theme: ThemeData(colorSchemeSeed: Colors.teal),
          home: const RulesAndBudgetsPage(showDrawer: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> edit(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    final amount = find.widgetWithText(TextField, 'Target amount');
    await tester.ensureVisible(amount);
    await tester.enterText(amount, '150');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
  }

  void verify() {
    expect(nodes.byId(template.id)!.money!.targetAmount, 150);
    for (final old in before.where((n) => n.isInstance)) {
      expect(
        nodes.byId(old.id),
        refreshedIds.contains(old.id)
            ? old.copyWith(money: old.money!.copyWith(targetAmount: 150))
            : old,
      );
    }
    final row = waterfall.state.rows.singleWhere(
      (r) => r.sourceId == refreshedId,
    );
    expect(row.amount, -150);
    expect(row.runningBalance, oldBalance - 50 * refreshedIds.length);
    expect(undo.state.undoStack, hasLength(1));
  }

  void verifyUndo() {
    undo.undo();
    expect(nodes.state, before);
    undo.redo();
    expect(nodes.byId(refreshedId)!.money!.targetAmount, 150);
  }
}
