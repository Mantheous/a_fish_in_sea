import 'package:a_fish_in_sea/finances/model/expense_catagory_and_tier.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';

class Expense {
  String name;
  double maxAmount;
  double current;
  DateTime? dueDate;
  ExpenseCatagory type;
  List<Transaction>? transactions;

  // I need to finish implementing the toJson and fromJson methods for this class
  // Then I need to set up a UI to view each expense

  Expense({
    required this.name,
    required this.maxAmount,
    this.current = 0,
    this.dueDate,
    this.type = ExpenseCatagory.unclasified,
    this.transactions,
  });

  factory Expense.fromJson(Map<String, dynamic> json) => Expense(
    name: json["name"] as String,
    maxAmount: (json["maxAmount"] as num).toDouble(),
    current: (json["current"] as num).toDouble(),
    dueDate: json["dueDate"] != null
        ? DateTime.parse(json["dueDate"] as String)
        : null,
    type: ExpenseCatagory.values.firstWhere((e) => e.name == json["type"]),
    transactions: (json["transactions"] as List<dynamic>?)
        ?.map((t) => Transaction.fromJson(t as Map<String, dynamic>))
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    "name": name,
    "maxAmount": maxAmount,
    "current": current,
    "dueDate": dueDate?.toIso8601String(),
    "type": type.name,
    "transactions": transactions?.map((t) => t.toJson()).toList(),
  };
}

enum ExpenseTimeTier { day, week, month, quarter, year, decade }
