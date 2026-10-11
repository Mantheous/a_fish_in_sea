import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

/// Spike: proves the Patrol web pipeline (build -> serve -> Playwright
/// Chromium -> widget-tree taps) works on the loop host before we invest
/// in real behavioral tests.
void main() {
  patrolTest('smoke: widget-tree tap increments the counter', ($) async {
    await $.pumpWidgetAndSettle(
      const MaterialApp(home: _CounterPage()),
    );
    expect($('0').visible, true);
    await $(FloatingActionButton).tap();
    await $.pumpAndSettle();
    expect($('1').visible, true);
  });
}

class _CounterPage extends StatefulWidget {
  const _CounterPage();

  @override
  State<_CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<_CounterPage> {
  int _count = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(child: Text('$_count')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _count++),
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
