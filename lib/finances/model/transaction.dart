import 'package:a_fish_in_sea/finances/model/expense_catagory_and_tier.dart';
import 'package:intl/intl.dart';

class Transaction {
  //int id;
  double amount;
  DateTime date;
  String description;
  ExpenseCategory type;

  static final formatter = DateFormat('MM/dd/yy');

  // This class esentially is just made from parsing through the csv file.
  // It needs to be stored seperately because I need to assosiate them to a specific expense
  // ID hasn't been implemented yet.
  // ID needs to be a unique number probably generated on creation
  Transaction({
    required this.amount,
    required this.date,
    required this.description,
    this.type = ExpenseCategory.unclasified,
  });

  factory Transaction.fromCSVRow(List<dynamic> row) {
    if (row[3] == "Debit") {
      row[4] = -row[4];
    }

    return Transaction(
      amount: row[4].toDouble(),
      date: formatter.parse(row[2]),
      description: row[1],
    );
  }

  factory Transaction.fromJson(Map<String, dynamic> json) {
    return Transaction(
      //id: json["id"] as double,
      amount: json["amount"] as double,
      date: json["date"] = formatter.parse(json["date"] as String),
      description: json["description"] as String,
      type: ExpenseCategory.values.firstWhere((e) => e.name == json["type"]),
    );
  }

  Map<String, dynamic> toJson() => {
    "amount": amount,
    "date": formatter.format(date),
    "description": description,
    "type": type.name,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true; // same instance
    if (other.runtimeType != runtimeType) return false;

    return other is Transaction &&
        other.amount == amount &&
        other.date == date &&
        other.description == description &&
        other.type == type;
  }

  bool isSameTransaction(Transaction other) {
    return other.amount == amount &&
        other.date == date &&
        other.description == description;
  }
}
