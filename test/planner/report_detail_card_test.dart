import 'package:a_fish_in_sea/planner/service/calendar_report.dart';
import 'package:a_fish_in_sea/planner/view/report_detail_card.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ReportBlock _block({
  required ReportBlockKind kind,
  String displayId = 'report:r1',
  String title = 'Read chapter',
  ReportStatus? status,
}) => ReportBlock(
  displayId: displayId,
  title: title,
  start: DateTime(2026, 10, 5, 9, 5),
  end: DateTime(2026, 10, 5, 9, 50),
  kind: kind,
  status: status,
  recordable: true,
);

Future<void> _pump(WidgetTester tester, Widget card) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: card)),
  ),
);

void main() {
  group('report labels', () {
    test('duration is compact and keeps hours separate', () {
      expect(reportDurationLabel(const Duration(minutes: 45)), '45m');
      expect(reportDurationLabel(const Duration(hours: 1)), '1h');
      expect(
        reportDurationLabel(const Duration(hours: 1, minutes: 5)),
        '1h 5m',
      );
      expect(reportDurationLabel(const Duration(seconds: 30)), '0m');
    });

    test('interval shows the recorded range and length', () {
      expect(
        reportIntervalLabel(
          _block(kind: ReportBlockKind.accepted),
          now: DateTime(2026, 10, 5, 12),
        ),
        '9:05 AM – 9:50 AM · 45m',
      );
    });

    test('live interval counts from the recording start', () {
      expect(
        reportIntervalLabel(
          _block(kind: ReportBlockKind.live, displayId: 'report:live:e1'),
          now: DateTime(2026, 10, 5, 9, 50),
        ),
        'Recording since 9:05 AM · 45m so far',
      );
    });

    test('status labels read as attendance, not enum names', () {
      expect(reportStatusLabel(ReportStatus.attended), 'Attended');
      expect(reportStatusLabel(ReportStatus.partial), 'Partially attended');
      expect(reportStatusLabel(ReportStatus.missed), 'Missed');
      expect(reportStatusLabel(ReportStatus.extra), 'Extra time');
    });
  });

  group('SelectedReportCard', () {
    testWidgets('shows the selected report and records again', (tester) async {
      var recorded = 0;
      await _pump(
        tester,
        SelectedReportCard(
          report: _block(
            kind: ReportBlockKind.accepted,
            status: ReportStatus.partial,
          ),
          eventSubject: 'Event e1',
          onRecord: () => recorded++,
        ),
      );

      expect(find.text('Report'), findsOneWidget);
      expect(find.text('Read chapter'), findsOneWidget);
      expect(find.text('9:05 AM – 9:50 AM · 45m'), findsOneWidget);
      expect(find.text('Partially attended'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('report-record:report:r1')));
      expect(recorded, 1);
    });

    testWidgets('hides a title that repeats the event subject', (tester) async {
      await _pump(
        tester,
        SelectedReportCard(
          report: _block(kind: ReportBlockKind.accepted, title: 'Event e1'),
          eventSubject: 'Event e1',
        ),
      );

      expect(find.text('Event e1'), findsNothing);
      expect(find.text('9:05 AM – 9:50 AM · 45m'), findsOneWidget);
    });

    testWidgets('ownerless report has no record button', (tester) async {
      await _pump(
        tester,
        SelectedReportCard(
          report: ReportBlock(
            displayId: 'report:r1',
            title: 'Typed-in report',
            start: DateTime(2026, 10, 5, 9, 5),
            end: DateTime(2026, 10, 5, 9, 50),
            kind: ReportBlockKind.accepted,
            status: ReportStatus.attended,
          ),
          eventSubject: 'Event e1',
          onRecord: () {},
        ),
      );

      expect(find.text('Record again'), findsNothing);
      expect(
        find.byKey(const ValueKey('report-record:report:r1')),
        findsNothing,
      );
    });

    testWidgets('live report has no record button', (tester) async {
      await _pump(
        tester,
        SelectedReportCard(
          report: _block(
            kind: ReportBlockKind.live,
            displayId: 'report:live:e1',
          ),
          eventSubject: 'Event e1',
          onRecord: () {},
        ),
      );

      expect(find.text('Recording now'), findsOneWidget);
      expect(find.textContaining('Recording since 9:05 AM'), findsOneWidget);
      expect(find.text('Record again'), findsNothing);
      expect(
        find.byKey(const ValueKey('report-record:report:live:e1')),
        findsNothing,
      );
    });
  });
}
