import 'dart:math';

import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/places_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:a_fish_in_sea/reporting/model/reported_entry.dart';
import 'package:a_fish_in_sea/reporting/view/day_review_screen.dart';
import 'package:a_fish_in_sea/reporting/view/time_range_dial.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class _MockStorage extends Mock implements Storage {}

void main() {
  group('dial angle math', () {
    test('midnight is top, 6am right, noon bottom', () {
      expect(dialAngleForMinutes(0), 0);
      expect(dialAngleForMinutes(360), closeTo(pi / 2, 1e-9));
      expect(dialAngleForMinutes(720), closeTo(pi, 1e-9));
      expect(dialAngleForMinutes(1080), closeTo(3 * pi / 2, 1e-9));
    });

    test('minutes round-trip through angles', () {
      for (final m in [0, 1, 59, 360, 539, 720, 1080, 1439]) {
        expect(
          minutesForDialAngle(dialAngleForMinutes(m)),
          m,
          reason: 'minute $m',
        );
      }
    });

    test('negative angles normalize clockwise', () {
      expect(minutesForDialAngle(-pi / 2), 1080);
    });

    test('snap rounds and wraps past midnight', () {
      expect(snapDayMinutes(1439, 15), 0);
      expect(snapDayMinutes(1428, 15), 1425);
      expect(snapDayMinutes(7, 5), 5);
      expect(snapDayMinutes(720, 1), 720);
    });

    test('clockwise duration wraps through midnight', () {
      expect(clockwiseMinutes(540, 590), 50);
      expect(clockwiseMinutes(1380, 60), 120);
      expect(clockwiseMinutes(0, 0), 0);
    });

    test('duration label formats hours and minutes', () {
      expect(formatDialDuration(45), '45m');
      expect(formatDialDuration(60), '1h');
      expect(formatDialDuration(90), '1h 30m');
    });
  });

  group('TimeRangeDial widget', () {
    testWidgets('tapping near the end handle moves the end time',
        (tester) async {
      TimeOfDay? changedEnd;
      TimeOfDay? changedStart;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimeRangeDial(
              start: const TimeOfDay(hour: 9, minute: 0),
              end: const TimeOfDay(hour: 10, minute: 0),
              snapMinutes: 60,
              onStartChanged: (v) => changedStart = v,
              onEndChanged: (v) => changedEnd = v,
            ),
          ),
        ),
      );
      final center = tester.getCenter(find.byType(TimeRangeDial));
      // Dial radius is size/2 - 13 = 91. Bottom of the dial is 12:00,
      // nearest to the 10:00 end handle (120m away vs 180m for start).
      await tester.tapAt(center + const Offset(0, 91));
      await tester.pump();
      expect(changedEnd, const TimeOfDay(hour: 12, minute: 0));
      expect(changedStart, isNull);
    });

    testWidgets('summary line shows range and duration', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimeRangeDial(
              start: const TimeOfDay(hour: 9, minute: 0),
              end: const TimeOfDay(hour: 9, minute: 45),
              onStartChanged: (_) {},
              onEndChanged: (_) {},
            ),
          ),
        ),
      );
      expect(find.textContaining('45m'), findsOneWidget);
    });

    testWidgets('dragging a handle moves it (standalone, no sheet)',
        (tester) async {
      TimeOfDay? changedStart;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: TimeRangeDial(
                start: const TimeOfDay(hour: 9, minute: 0),
                end: const TimeOfDay(hour: 10, minute: 0),
                snapMinutes: 60,
                onStartChanged: (v) => changedStart = v,
                onEndChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      final face = find.descendant(
        of: find.byType(TimeRangeDial),
        matching: find.byType(CustomPaint),
      );
      expect(face, findsOneWidget);
      final dialCenter = tester.getCenter(face);
      final gesture =
          await tester.startGesture(dialCenter + const Offset(64.35, 64.35));
      await gesture.moveTo(dialCenter + const Offset(91, 0),
          timeStamp: const Duration(milliseconds: 100));
      await gesture.up(timeStamp: const Duration(milliseconds: 120));
      await tester.pump();
      expect(changedStart, const TimeOfDay(hour: 6, minute: 0));
    });
  });

  group('reported editor sheet', () {
    testWidgets('dragging the dial start handle changes the saved entry',
        (tester) async {
      final storage = _MockStorage();
      when(() => storage.read(any())).thenReturn(null);
      when(() => storage.write(any(), any())).thenAnswer((_) async {});
      when(() => storage.delete(any())).thenAnswer((_) async {});
      when(() => storage.clear()).thenAnswer((_) async {});
      HydratedBloc.storage = storage;

      final reporting = ReportingCubit();
      final places = PlacesCubit();
      final settings = SettingsCubit();
      addTearDown(() async {
        await reporting.close();
        await places.close();
        await settings.close();
      });

      final day = DateTime(2026, 10, 11);
      final entry = ReportedEntry(
        id: 'rep:e1',
        eventId: 'e1',
        title: 'Dial test',
        start: DateTime(2026, 10, 11, 9),
        end: DateTime(2026, 10, 11, 10),
        status: ReportStatus.attended,
      );
      await tester.pumpWidget(
        // Providers sit above MaterialApp: the editor opens as a new
        // route, whose context only sees ancestors of the Navigator.
        MultiBlocProvider(
          providers: [
            BlocProvider.value(value: reporting),
            BlocProvider.value(value: places),
            BlocProvider.value(value: settings),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => showReportedEditor(
                    context,
                    day: day,
                    entry: entry,
                  ),
                  child: const Text('open editor'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open editor'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(TimeRangeDial), findsOneWidget);

      // Dial geometry: face is a 208px CustomPaint, radius 91.
      // (Locate the face itself: the column top also contains the title.)
      final face = find.descendant(
        of: find.byType(TimeRangeDial),
        matching: find.byType(CustomPaint),
      );
      expect(face, findsOneWidget);
      final dialCenter = tester.getCenter(face);
      // Start handle sits at 9:00 (135° clockwise from top). Drag it
      // horizontally to noon (same y the whole way).
      final startPos = dialCenter + const Offset(64.35, 64.35);
      final noonLeft = Offset(dialCenter.dx, startPos.dy);
      final gesture = await tester.startGesture(startPos);
      // Stream several small moves like real touch input: a single jump
      // only starts the pan, and only follow-up moves deliver updates.
      const steps = 8;
      for (var i = 1; i <= steps; i++) {
        final t = i / steps;
        await gesture.moveTo(
          Offset(
            startPos.dx + (noonLeft.dx - startPos.dx) * t,
            startPos.dy + (noonLeft.dy - startPos.dy) * t,
          ),
          timeStamp: Duration(milliseconds: 50 + i * 16),
        );
      }
      await gesture.up(timeStamp: const Duration(milliseconds: 200));
      await tester.pump();

      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final saved = reporting.entriesForDay(day);
      expect(saved, hasLength(1));
      expect(saved.single.start, DateTime(2026, 10, 11, 12));
      expect(saved.single.end, DateTime(2026, 10, 11, 13));
      expect(saved.single.auto, isFalse);
    });
  });
}
