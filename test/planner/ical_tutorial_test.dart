import 'package:a_fish_in_sea/planner/view/feed_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('iCal tutorial shows Canvas and Learning Suite steps',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showIcalTutorial(context),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('How do I find my iCal link?'), findsOneWidget);
    expect(
      find.text('Canvas — one link covers every class'),
      findsOneWidget,
    );
    expect(
      find.text('Learning Suite — one link per class'),
      findsOneWidget,
    );
    // Key distinguishing steps for each source.
    expect(find.textContaining('Calendar Feed'), findsWidgets);
    expect(find.textContaining('Get iCalendar Feed'), findsWidgets);
    expect(find.textContaining('instructure.com/feeds'), findsOneWidget);
    expect(find.textContaining('learningsuite.byu.edu'), findsOneWidget);

    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.text('How do I find my iCal link?'), findsNothing);
  });
}
