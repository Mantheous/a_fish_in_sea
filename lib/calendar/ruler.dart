import 'package:flutter/material.dart';
import 'ruler_timestamp.dart';
class Ruler extends StatelessWidget {
  const Ruler({super.key});
  static const double rowHeight = 60.0;
  
  makeTimeWidgets(startTime, endTime) {
    List<Widget> widgets = [];
    for (var hour = startTime; hour <= endTime; hour++) {
      widgets.add(RulerTimestamp(time: "$hour:00"));
      widgets.add(RulerTimestamp(time: "$hour:30"));
    }
    return widgets;
  }


  @override
  Widget build(BuildContext context) {
    
    return Column(
      children: makeTimeWidgets(4, 21),
    );
  }
}