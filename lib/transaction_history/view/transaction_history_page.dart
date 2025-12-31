import 'package:a_fish_in_sea/navigation/view/navigation_bar.dart';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:csv/csv.dart';
import 'package:flutter/services.dart';

// TODO Before production this needs to be switched over a better solution
// I should use Plaid API to get the data dirrectly from the bank.
// This will also resolve the edge case where there are duplicate enteries
// that interupt a merge

class TransactionHistoryPage extends StatelessWidget {
  final ThemeData theme;
  const TransactionHistoryPage({super.key, required this.theme});
  static const csvPath = "a_fish_in_sea/lib/data/2025-10-11_AshtonChecking...9371.csv";

  Future<List<List<dynamic>>> loadData() async {
    final csvString = await rootBundle.loadString('lib/data/2025-10-11_AshtonChecking...9371.csv');
    final bigList = CsvToListConverter().convert(csvString);
    
    return bigList;
  }

  DateTime parseDate(String dateString) {
    // 10/10/25
    final year = int.parse("20${dateString.substring(6, 8)}");
    final day = int.parse(dateString.substring(3,5));
    final month = int.parse(dateString.substring(0,2));
    return DateTime(year, month, day);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: NavBar(),
      body: Center(child:AspectRatio(
        aspectRatio: 0.5, 
        child: FutureBuilder(future: loadData(), builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          final dataRows = snapshot.data!.skip(1);

          return LineChart(
          LineChartData(
            lineBarsData: [LineChartBarData(
              spots: dataRows.map((x) { 
                final date = parseDate(x[2]);
                final dayNum = (date).difference(DateTime(2000)).inDays;
                return FlSpot(dayNum as double, x[4] as double);
                }).toList()
                       


              // spots: [
              //   //Place holder Data
              //   // TODO Put in real data
              //   FlSpot(0, 0),
              //   FlSpot(1, 1),
              //   FlSpot(2, 5),
              //   FlSpot(3, 2),
              //   FlSpot(4, 6),
              // ]
          )]
          )
        );
        })
        
      )
    ));
  }
}