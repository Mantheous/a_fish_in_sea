import 'package:flutter_test/flutter_test.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';

void main() {
  test('Transaction.fromPlaid parses a Plaid JSON response', () {
    final plaidJson = {
      'transaction_id': 'txn_123',
      'account_id': 'acc_456',
      'amount': 13.41,
      'date': '2025-10-11',
      'name': 'Grocery Store',
      'category': ['Food and Drink', 'Groceries'],
      'pending': false,
    };

    final tx = Transaction.fromPlaid(plaidJson);

    expect(tx.id, 'txn_123');
    expect(tx.accountId, 'acc_456');
    expect(tx.amount, -13.41); // Plaid positive = debit, we flip
    expect(tx.date, DateTime(2025, 10, 11));
    expect(tx.name, 'Grocery Store');
    expect(tx.category, 'Food and Drink > Groceries');
    expect(tx.pending, false);
    expect(tx.isAssigned, false);
  });

  test('Transaction toJson/fromJson roundtrip', () {
    final original = Transaction(
      id: 'txn_123',
      accountId: 'acc_456',
      amount: -10.00,
      date: DateTime(2025, 10, 11),
      name: 'Test Transaction',
      category: 'Food',
    );
    final json = original.toJson();
    final restored = Transaction.fromJson(json);
    expect(restored, equals(original));
  });

  test('Transaction assignment', () {
    final tx = Transaction(
      id: 'txn_123',
      accountId: 'acc_456',
      amount: -10.00,
      date: DateTime(2025, 10, 11),
      name: 'Test',
    );

    expect(tx.isAssigned, false);

    final assigned = tx.copyWith(assignedExpenseId: 'exp_789');
    expect(assigned.isAssigned, true);
    expect(assigned.assignedExpenseId, 'exp_789');

    final cleared = assigned.copyWith(clearAssignment: true);
    expect(cleared.isAssigned, false);
  });

  test('Transaction.fromPlaid handles income (negative Plaid amount)', () {
    final plaidJson = {
      'transaction_id': 'txn_income',
      'account_id': 'acc_456',
      'amount': -1000.00, // Plaid negative = credit/income
      'date': '2025-10-15',
      'name': 'Payroll',
      'pending': false,
    };

    final tx = Transaction.fromPlaid(plaidJson);
    expect(tx.amount, 1000.00); // Income should be positive
  });
}
