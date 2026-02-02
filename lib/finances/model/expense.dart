import 'package:a_fish_in_sea/finances/model/expense_catagory_and_tier.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:equatable/equatable.dart';

class Expense extends Equatable {
  final String name;
  final double maxAmount;
  final DateTime? dueDate;
  final ExpenseCategory type;
  final ExpenseTimeTier timeTier;
  final List<Transaction> transactions;
  final bool fixed;

  String get typeCapitalized =>
      type.name[0].toUpperCase() + type.name.substring(1);

  double get current {
    if (transactions.isEmpty) return 0.0;
    return transactions.fold(0.0, (sum, t) => sum + t.amount);
  }

  bool get paid {
    return current >= maxAmount;
  }

  const Expense({
    required this.name,
    required this.maxAmount,
    this.dueDate,
    this.type = ExpenseCategory.unclasified,
    this.timeTier = ExpenseTimeTier.month,
    this.transactions = const [],
    this.fixed = true,
  });

  Expense copyWith({
    String? name,
    double? maxAmount,
    DateTime? dueDate,
    ExpenseCategory? type,
    ExpenseTimeTier? timeTier,
    List<Transaction>? transactions,
  }) {
    return Expense(
      name: name ?? this.name,
      maxAmount: maxAmount ?? this.maxAmount,
      dueDate: dueDate ?? this.dueDate,
      type: type ?? this.type,
      timeTier: timeTier ?? this.timeTier,
      transactions: transactions ?? this.transactions,
    );
  }

  factory Expense.fromJson(Map<String, dynamic> json) => Expense(
    name: json["name"] as String,
    maxAmount: (json["maxAmount"] as num).toDouble(),
    dueDate: json["dueDate"] != null
        ? DateTime.parse(json["dueDate"] as String)
        : null,
    type: ExpenseCategory.values.firstWhere((e) => e.name == json["type"]),
    timeTier: ExpenseTimeTier.values.firstWhere(
      (e) => e.name == json["timeTier"],
    ),
    transactions: (json["transactions"] as List<dynamic>?)!
        .map((t) => Transaction.fromJson(t as Map<String, dynamic>))
        .toList(),
  );

  const Expense.empty()
    : name = '',
      maxAmount = 0,
      dueDate = null,
      type = ExpenseCategory.unclasified,
      timeTier = ExpenseTimeTier.month,
      transactions = const [],
      fixed = true;

  Map<String, dynamic> toJson() => {
    "name": name,
    "maxAmount": maxAmount,
    "current": current,
    "dueDate": dueDate?.toIso8601String(),
    "type": type.name,
    "timeTier": timeTier.name,
    "transactions": transactions.map((t) => t.toJson()).toList(),
  };

  @override
  List<Object?> get props => [
    name,
    maxAmount,
    dueDate,
    type,
    timeTier,
    transactions,
  ];
}
