import 'package:a_fish_in_sea/finances/model/expense_catagory_and_tier.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';

void main() {
  test('Transaction.fromCSVRow parses a normal CSV row', () {
    final csvRow = [9371, "Description", "10/11/25", "Debit", 13.41, 567.52];

    final tx = Transaction.fromCSVRow(csvRow);

    // Replace these assertions with your Transaction fields
    expect(tx.date, DateTime(2025, 10, 11));
    expect(tx.description, contains('Description'));
    expect(tx.amount, equals(-13.41));
    expect(tx.type, ExpenseCategory.unclasified);
  });

  test('Transaction toJson/fromJson roundtrip', () {
    final original = Transaction(
      amount: 10,
      date: DateTime(2025, 10, 11),
      description: "Test Transaction",
      type: ExpenseCategory.food,
    );
    final json = original.toJson();
    final restored = Transaction.fromJson(json);
    expect(restored, equals(original));
  });

  group('isSameTransaction', () {
    test('returns true for transactions with the same amount, date, and description', () {
      // TODO: Implement test
    });

    test('returns false if the amount is different', () {
      // TODO: Implement test
    });

    test('returns false if the date is different', () {
      // TODO: Implement test
    });

    test('returns false if the description is different', () {
      // TODO: Implement test
    });

    test('returns true even if the type is different', () {
      // TODO: Implement test
    });
  });

  group('Equality Operator (==)', () {
    test('returns true for two identical transactions', () {
      // TODO: Implement test
    });

    test('returns false if any field is different', () {
      // TODO: Implement test
    });
  });

  group('CSV Parsing Edge Cases', () {
    test('handles credit transactions correctly', () {
      // TODO: Implement test
    });

    test('handles leading/trailing whitespace in description', () {
      // TODO: Implement test
    });

    test('handles amounts with dollar signs or commas', () {
      // TODO: Implement test
    });

    test('handles different date formats', () {
      // TODO: Implement test
    });
  });
}
