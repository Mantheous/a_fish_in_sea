class Transaction {
  //int id;
  double amount;
  DateTime date;
  String description;
  ExpenseCatagory type;

  //static int _nextId = 0;

  // This class esentially is just made from parsing through the csv file.
  // It needs to be stored seperately because I need to assosiate them to a specific expense
  // ID hasn't been implemented yet.
  // ID needs to be a unique number probably generated on creation
  Transaction({
    required this.amount,
    required this.date,
    required this.description,
    this.type = ExpenseCatagory.unclasified,
  });

  factory Transaction.fromJson(Map<String, dynamic> json) => Transaction(
    //id: json["id"] as double,
    amount: json["amount"] as double,
    date: json["date"] = DateTime.parse(["date"] as String),
    description: json["description"] as String,
    type: ExpenseCatagory.values.firstWhere((e) => e.name == json["type"])
  );

  Map<String, dynamic> toJson() => {
    "amount": amount,
    "date": date.toIso8601String(),
    "description": description,
    "type": type.name,
  };
}

enum ExpenseCatagory {
  unclasified,
  food,
  housing,
  transportation,
  tuition,
  entertainment,
  tithing,
  savings,
  miscellaneous,
}

enum ExpenseTimeTier {
  day,
  week,
  month,
  quarter,
  year,
  decade,
}