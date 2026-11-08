import 'package:a_fish_in_sea/planner/service/calendar_report.dart';
import 'package:a_fish_in_sea/planner/view/calendar_report_lane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Run with TZ=America/Denver to exercise both clock changes.
  for (final day in [DateTime(2026, 3, 8), DateTime(2026, 11, 1)]) {
    final before = DateTime(day.year, day.month, day.day, 0, 30);
    final after = DateTime(
      day.year,
      day.month,
      day.day,
      day.month == 3 ? 3 : 2,
      30,
    );
    for (final top in [true, false]) {
      for (final forward in [true, false]) {
        testWidgets('$day ${top ? 'start' : 'end'} follows clock time '
            '${forward ? 'forward' : 'backward'} across the change', (
          tester,
        ) async {
          await tester.binding.setSurfaceSize(const Size(800, 900));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          const scale = 2.0;
          final original = forward ? before : after;
          final target = forward ? after : before;
          var block = ReportBlock(
            displayId: 'report:resize',
            title: 'Clock change report',
            start: top ? original : day,
            end: top ? DateTime(day.year, day.month, day.day, 5) : original,
            kind: ReportBlockKind.accepted,
          );
          final unchangedEdge = top ? block.end : block.start;
          DateTime? savedStart;
          DateTime? savedEnd;
          var commits = 0;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 240,
                    height: 720,
                    child: StatefulBuilder(
                      builder: (context, setState) => ReportLaneView(
                        blocks: [block],
                        day: day,
                        startHour: 0,
                        endHour: 6,
                        pixelsPerMinute: scale,
                        selectedId: block.displayId,
                        colorFor: (_) => Colors.blue,
                        onTap: (_) {},
                        onIntervalChanged: (_, start, end) {
                          savedStart = start;
                          savedEnd = end;
                          commits++;
                          setState(() {
                            block = block.copyWith(start: start, end: end);
                          });
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );

          final handle = find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.label ==
                    'Drag to adjust report ${top ? 'start' : 'end'}',
          );
          final origin = tester.getCenter(handle);
          final delta =
              ((target.hour - original.hour) * 60 +
                  target.minute -
                  original.minute) *
              scale;
          final gesture = await tester.startGesture(origin);
          // Resolve the drag recognizer before measuring movement.
          await gesture.moveBy(Offset(0, delta.sign * 24));
          await tester.pump();
          final pointer = origin + Offset(0, delta.sign * 24 + delta);
          await gesture.moveTo(pointer);
          await tester.pump();

          expect(tester.getCenter(handle).dy, closeTo(origin.dy + delta, 1));
          expect(commits, 0, reason: 'preview must stay local until release');
          final label = reportChipTimeLabel(
            block.copyWith(
              start: top ? target : null,
              end: top ? null : target,
            ),
          );
          expect(find.text(label), findsOneWidget);

          await gesture.up();
          await tester.pump();

          expect(commits, 1);
          expect(top ? savedStart : savedEnd, target);
          expect(top ? savedEnd : savedStart, unchangedEdge);
          expect(find.text(label), findsOneWidget);
          expect(tester.getCenter(handle).dy, closeTo(origin.dy + delta, 1));
        });
      }
    }
  }
}
