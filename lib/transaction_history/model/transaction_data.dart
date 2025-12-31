// import 'package:csv/csv.dart';
// import 'dart:io';

// class TransactionData {
//   List<List<dynamic>> data;
//   static const csvPath = "a_fish_in_sea/lib/data/2025-10-11_AshtonChecking...9371.csv";

//   TransactionData({required this.data});

//   factory TransactionData.init() async {
//     final dataFile = File(csvPath);
//     data = const CsvToListConverter().convert(await dataFile.readAsString());
//     return TransactionData(data: data);
//   }
// }