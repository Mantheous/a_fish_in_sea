import 'package:flutter/material.dart';

class RulerTimestamp extends StatelessWidget {
  const RulerTimestamp({super.key, required this.time});
  final String time;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8.0, top: 8.0, bottom: 8.0), 
      child: Text(time, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
    ));
  }
}