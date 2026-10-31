import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/calendar_report.dart';
import 'package:a_fish_in_sea/planner/service/report_adjustment.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:a_fish_in_sea/reporting/service/day_plan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

class MockFeedCubit extends Mock implements FeedCubit {}

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  for (final action in ['delete', 'resize', 'move', 'stale']) {
    test('$action targets only the selected recurring report day', () async {
      final calendar = CalendarCubit();
      final feeds = MockFeedCubit();
      when(() => feeds.state).thenReturn(const []);
      when(() => feeds.visibleEvents(any())).thenAnswer(
        (call) => call.positionalArguments.single as List<PlannerEvent>,
      );
      final nodes = NodeCubit();
      final reporting = ReportingCubit();
      addTearDown(() async {
        await reporting.close();
        await nodes.close();
        await calendar.close();
      });
      final monday = DateTime(2026, 10, 5);
      final tuesday = DateTime(2026, 10, 6);
      calendar.addEvent(
        PlannerEvent(
          id: 'daily',
          subject: 'Study',
          start: monday.add(const Duration(hours: 9)),
          end: monday.add(const Duration(hours: 10)),
          recurrenceRule: 'FREQ=DAILY',
        ),
      );
      for (final day in [monday, tuesday]) {
        reporting.runAutoReport(
          day: day,
          planned: daySlices(calendar, feeds, day),
          dwells: [],
          placeNames: {},
        );
        reporting.upsertEntry(day, reporting.entriesForDay(day).single);
      }
      final first = reporting.entriesForDay(monday).single;
      final second = reporting.entriesForDay(tuesday).single;
      expect(first.id, second.id);
      // Existing device payloads keep the same ids and need no migration.
      final restored = reporting.fromJson(reporting.toJson(reporting.state))!;
      expect(restored['2026-10-06']!.single.id, first.id);
      final blocks = buildReportBlocks(
        visibleEvents: calendar.state,
        nodes: [],
        reportsByDay: restored,
      );
      expect(blocks, hasLength(2));
      expect(blocks.map((b) => b.displayId).toSet(), hasLength(2));
      expect(
        findReportEntryByDisplayId(restored, blocks.last.displayId)?.start,
        second.start,
      );
      expect(
        findReportEntryByDisplayId(restored, 'report:${first.id}'),
        isNull,
      );
      if (action == 'stale') reporting.deleteEntry(tuesday, second.id);
      if (action == 'delete' || action == 'stale') {
        expect(
          deleteReportedBlock(
            reporting: reporting,
            calendar: calendar,
            nodes: nodes,
            block: blocks.last,
          ),
          action != 'stale',
        );
        expect(reporting.entriesForDay(tuesday), isEmpty);
      } else {
        final start = second.start.add(
          Duration(days: action == 'move' ? 1 : 0, minutes: 15),
        );
        expect(
          applyReportedInterval(
            reporting: reporting,
            calendar: calendar,
            nodes: nodes,
            block: blocks.last,
            start: start,
            end: start.add(const Duration(minutes: 30)),
          ),
          isTrue,
        );
        final updated = reporting.entriesForDay(start).single;
        expect(updated.id, second.id);
        expect(updated.start, start);
        expect(updated.auto, isFalse);
        if (action == 'move') {
          expect(reporting.entriesForDay(tuesday), isEmpty);
        }
      }
      expect(reporting.entriesForDay(monday), [first]);
      expect(calendar.byId('daily')!.actualStart, isNull);
    });
  }
}
