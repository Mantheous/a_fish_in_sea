class Expense {
  double maxAmount;
  double current;
  DateTime? dueDate;
  ExpenseCatagory? type;
  
  //I wrote down the other fields this needs to hold
  // I am working on the transaction class right now

  Expense({
    required this.maxAmount,
    this.current = 0,
    this.dueDate,
    //this.subExpenses = const [],
  });

  factory Expense.fromJson(Map<String, dynamic> json) => Expense(
    maxAmount: json["maxAmount"] as double,
    current: json["current"] as double,
    dueDate: json["dueDate"] != null
      ? DateTime.parse(["dueDate"] as String)
      : null,
    
    //subExpenses: json["subExpenses"]?.map((e)=> Expense.fromJson(e)).toList(),
  );

  Map<String, dynamic> toJson() => {
    "maxAmount": maxAmount,
    "current": current,
    "dueDate": dueDate?.toIso8601String(),
    //"subExpenses": subExpenses?.map((e) => e.toJson()),
  };
}

enum ExpenseCatagory {
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