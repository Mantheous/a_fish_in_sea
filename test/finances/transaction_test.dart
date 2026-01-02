import 'package:flutter_test/flutter_test.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';

void main() {
  test('Transaction.fromCSVRow parses a normal CSV row', () {
    // Replace with a realistic CSV row matching your CSV layout
    final csvRow = ['9371', "Description", "10/11/25", "Debit", "13.41", "567.52"];

    final tx = Transaction.fromCSVRow(csvRow);

    // Replace these assertions with your Transaction fields
    expect(tx.date, DateTime(2025, 10, 11));
    expect(tx.description, contains('Description'));
    expect(tx.amount, equals(13.41));
    expect(tx.type, ExpenseCatagory.unclasified);
  });

  test('Transaction toJson/fromJson roundtrip', () {
    final original = Transaction(amount: 10, date: DateTime(2025, 10, 11), description: "Test Transaction", type: ExpenseCatagory.food);
    final json = original.toJson();
    final restored = Transaction.fromJson(json);
    expect(restored, equals(original));
  });
}