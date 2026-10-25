import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/goal_progress_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

final _created = DateTime(2026, 10, 1, 9);

Node _node(
  String id, {
  List<String> parents = const [],
  MoneyFacet? money,
  AutoFacet? auto,
  NodeStatus status = NodeStatus.open,
  DateTime? completedAt,
}) => Node(
  id: id,
  title: id,
  parentIds: parents,
  createdAt: _created,
  money: money,
  auto: auto,
  status: status,
  completedAt: completedAt,
);

Transaction _txn(String id, double amount, {String? nodeId}) => Transaction(
  id: id,
  accountId: 'acct',
  amount: amount,
  date: _created,
  name: id,
  assignedNodeId: nodeId,
);

void main() {
  test('assigned transactions fill the gap when no actual is recorded', () {
    final snapshot = buildGoalProgressSnapshot(
      nodes: [
        _node(
          'food',
          money: const MoneyFacet(targetAmount: 100),
        ),
        _node(
          'groceries',
          parents: const ['food'],
          money: const MoneyFacet(targetAmount: 100),
        ),
      ],
      transactions: [_txn('t1', -40, nodeId: 'groceries')],
      now: _created,
    );

    expect(snapshot.moneyActualOf('groceries'), 40);
    expect(snapshot.progressOf('food'), closeTo(0.4, 1e-9));
  });

  test('a recorded actual wins over linked transaction amounts', () {
    final snapshot = buildGoalProgressSnapshot(
      nodes: [
        _node(
          'save',
          money: const MoneyFacet(
            targetAmount: 100,
            actualAmount: 30,
            linkedTransactionIds: ['t1'],
          ),
        ),
      ],
      transactions: [_txn('t1', -90)],
      now: _created,
    );

    expect(snapshot.moneyActualOf('save'), 30);
    expect(snapshot.progressOf('save'), closeTo(0.3, 1e-9));
  });

  test('child counts and automated readings are exposed per goal', () {
    final now = DateTime.now();
    final snapshot = buildGoalProgressSnapshot(
      nodes: [
        _node(
          'auto',
          auto: const AutoFacet(metric: AutoMetric.count, target: 2),
        ),
        _node(
          'done-child',
          parents: const ['auto'],
          status: NodeStatus.done,
          completedAt: now,
        ),
        _node('open-child', parents: const ['auto']),
      ],
      transactions: const [],
      now: now,
    );

    expect(snapshot.childCountOf('auto'), 2);
    expect(snapshot.childCountOf('open-child'), 0);
    final reading = snapshot.readingOf('auto');
    expect(reading, isNotNull);
    expect(reading!.actual, 1);
    // The automated goal reads its query, not its children's average.
    expect(snapshot.progressOf('auto'), closeTo(0.5, 1e-9));
  });
}
