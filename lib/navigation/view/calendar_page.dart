import 'package:a_fish_in_sea/navigation/view/navigation_bar.dart';
import 'package:flutter/material.dart';
import 'package:a_fish_in_sea/calendar/ruler.dart';

class CalendarPage extends StatelessWidget {
  const CalendarPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: NavBar(),
      body: const Padding(
          padding: EdgeInsets.all(8.0),
          child: SingleChildScrollView(
            child: Row(children: [
              Ruler(),
              Center(child: Text("Events"))
            ],),
          ),
        ));

  }
}