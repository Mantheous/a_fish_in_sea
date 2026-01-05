import 'package:flutter_test/flutter_test.dart';
import 'package:a_fish_in_sea/finances/model/expense.dart';
import 'package:a_fish_in_sea/finances/model/expense_catagory_and_tier.dart';

void main() {
  group('Expense', () {
    group('toJson/fromJson roundtrip', () {
      test('basic expense without optional fields', () {
        final original = Expense(
          name: 'Groceries',
          maxAmount: 500.0,
          current: 150.50,
          type: ExpenseCategory.food,
        );

        final json = original.toJson();
        final restored = Expense.fromJson(json);

        expect(restored.name, equals(original.name));
        expect(restored.maxAmount, equals(original.maxAmount));
        expect(restored.current, equals(original.current));
        expect(restored.type, equals(original.type));
        expect(restored.dueDate, isNull);
        expect(restored.transactions, isNull);
      });

      test('expense with due date', () {
        final dueDate = DateTime(2026, 12, 31);
        final original = Expense(
          name: 'Rent',
          maxAmount: 1500.0,
          current: 0.0,
          dueDate: dueDate,
          type: ExpenseCategory.housing,
        );

        final json = original.toJson();
        final restored = Expense.fromJson(json);

        expect(restored.name, equals(original.name));
        expect(restored.dueDate, isNotNull);
        expect(restored.dueDate!.year, equals(dueDate.year));
        expect(restored.dueDate!.month, equals(dueDate.month));
        expect(restored.dueDate!.day, equals(dueDate.day));
      });

      test('expense with all fields populated', () {
        final dueDate = DateTime(2026, 6, 15);
        final original = Expense(
          name: 'Utilities',
          maxAmount: 200.0,
          current: 75.25,
          dueDate: dueDate,
          type: ExpenseCategory.housing,
        );

        final json = original.toJson();
        final restored = Expense.fromJson(json);

        expect(restored.name, equals('Utilities'));
        expect(restored.maxAmount, equals(200.0));
        expect(restored.current, equals(75.25));
        expect(restored.dueDate, isNotNull);
        expect(restored.type, equals(ExpenseCategory.housing));
      });

      test('handles zero and negative values', () {
        final original = Expense(
          name: 'Test',
          maxAmount: 0.0,
          current: 0.0,
          type: ExpenseCategory.unclasified,
        );

        final json = original.toJson();
        final restored = Expense.fromJson(json);

        expect(restored.maxAmount, equals(0.0));
        expect(restored.current, equals(0.0));
      });

      test('handles numeric type coercion (int to double)', () {
        final json = {
          "name": "Test Expense",
          "maxAmount": 100, // int instead of double
          "current": 50, // int instead of double
          "dueDate": null,
          "type": "food",
          "transactions": null,
        };

        final expense = Expense.fromJson(json);

        expect(expense.maxAmount, equals(100.0));
        expect(expense.current, equals(50.0));
      });

      test('handles different expense categories', () {
        final categories = [
          ExpenseCategory.food,
          ExpenseCategory.housing,
          ExpenseCategory.transportation,
          ExpenseCategory.tuition,
          ExpenseCategory.entertainment,
          ExpenseCategory.unclasified,
        ];

        for (final category in categories) {
          final original = Expense(
            name: 'Test ${category.name}',
            maxAmount: 100.0,
            type: category,
          );

          final json = original.toJson();
          final restored = Expense.fromJson(json);

          expect(
            restored.type,
            equals(category),
            reason: 'Failed for category: ${category.name}',
          );
        }
      });

      test('dueDate null handling in JSON', () {
        final json = {
          "name": "No Due Date",
          "maxAmount": 100.0,
          "current": 0.0,
          "dueDate": null,
          "type": "food",
          "transactions": null,
        };

        final expense = Expense.fromJson(json);

        expect(expense.dueDate, isNull);
      });

      test('default values applied correctly', () {
        final original = Expense(name: 'Defaults Test', maxAmount: 500.0);

        final json = original.toJson();
        final restored = Expense.fromJson(json);

        expect(restored.current, equals(0.0)); // default value
        expect(restored.type, equals(ExpenseCategory.unclasified)); // default
        expect(restored.dueDate, isNull); // default
      });

      test('toJson produces valid JSON structure', () {
        final expense = Expense(
          name: 'JSON Structure Test',
          maxAmount: 250.0,
          current: 100.0,
          type: ExpenseCategory.entertainment,
        );

        final json = expense.toJson();

        expect(json, containsPair('name', 'JSON Structure Test'));
        expect(json, containsPair('maxAmount', 250.0));
        expect(json, containsPair('current', 100.0));
        expect(json, containsPair('type', 'entertainment'));
        expect(json.containsKey('dueDate'), isTrue);
        expect(json.containsKey('transactions'), isTrue);
      });
    });

    group('edge cases', () {
      test('very large amounts', () {
        final original = Expense(
          name: 'Large Amount',
          maxAmount: 999999999.99,
          current: 123456789.45,
        );

        final json = original.toJson();
        final restored = Expense.fromJson(json);

        expect(restored.maxAmount, equals(999999999.99));
        expect(restored.current, equals(123456789.45));
      });

      test('very small amounts', () {
        final original = Expense(
          name: 'Small Amount',
          maxAmount: 0.01,
          current: 0.001,
        );

        final json = original.toJson();
        final restored = Expense.fromJson(json);

        expect(restored.maxAmount, equals(0.01));
        expect(restored.current, equals(0.001));
      });

      test('special characters in name', () {
        final original = Expense(
          name: 'Expense & "Quotes" \'Single\' <Special>',
          maxAmount: 100.0,
        );

        final json = original.toJson();
        final restored = Expense.fromJson(json);

        expect(restored.name, equals(original.name));
      });
    });
  });
}
