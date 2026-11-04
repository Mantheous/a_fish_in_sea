import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/model/event_reschedule.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  late CalendarCubit calendar;
  late FeedCubit feeds;
  late String source;

  const original = '''BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:event-assignment-42
DTSTAMP:20291101T120000Z
DTSTART:20300101T090000Z
DTEND:20300101T100000Z
SUMMARY:Assignment
END:VEVENT
END:VCALENDAR
''';
  final changed = original
      .replaceAll('20300101', '20300102')
      .replaceAll('SUMMARY:Assignment', 'SUMMARY:Updated assignment');

  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    final undo = UndoCubit();
    calendar = CalendarCubit();
    final nodes = NodeCubit();
    final client = MockClient((_) async => http.Response(source, 200));
    source = original;
    feeds = FeedCubit(
      calendarCubit: calendar,
      nodeCubit: nodes,
      icalService: IcalService(client: client),
      googleService: GoogleCalendarService(baseUrl: () => '', userId: () => ''),
      proxyBase: () => 'http://localhost:1',
    );
    addTearDown(feeds.close);
    addTearDown(calendar.close);
    addTearDown(nodes.close);
    addTearDown(undo.close);
    addTearDown(client.close);
  });

  Future<PlannerEvent> import(FeedKind kind) async {
    feeds.addFeed(
      Feed(
        id: 'class',
        name: 'Class',
        url: 'https://example.com/class.ics',
        kind: kind,
      ),
    );
    await feeds.syncFeed('class');
    expect(feeds.state.single.lastError, isNull);
    return calendar.state.single;
  }

  test(
    'ordinary subscription tasks remain read-only and follow source times',
    () async {
      final event = await import(FeedKind.other);
      expect(event.isTask, isTrue);
      expect(feeds.isEventEditable(event), isFalse);
      // Even a stale local scheduling flag cannot freeze a subscription.
      calendar.updateEvent(event.copyWith(workTimeScheduled: true));
      source = changed;
      await feeds.syncFeed('class');
      final synced = calendar.state.single;
      expect(synced.start, event.start.add(const Duration(days: 1)));
      expect(synced.end, event.end.add(const Duration(days: 1)));
    },
  );

  test('unknown feed tasks remain read-only', () {
    final start = DateTime(2030, 1, 1);
    expect(
      feeds.isEventEditable(
        PlannerEvent(
          id: 'unknown',
          subject: 'Unknown',
          start: start,
          end: start,
          feedId: 'missing',
          isTask: true,
        ),
      ),
      isFalse,
    );
  });

  for (final kind in [FeedKind.canvas, FeedKind.learningSuite]) {
    test(
      '$kind untouched timed assignments follow source date changes',
      () async {
        final event = await import(kind);
        expect(feeds.isEventEditable(event), isTrue);
        expect(event.workTimeScheduled, isFalse);
        // A duration supplied by the source does not mean locally scheduled.
        expect(event.plannedDuration, const Duration(hours: 1));
        source = changed;
        await feeds.syncFeed('class');
        final synced = calendar.state.single;
        expect(synced.start, event.start.add(const Duration(days: 1)));
        expect(synced.end, event.end.add(const Duration(days: 1)));
        expect(synced.workTimeScheduled, isFalse);
      },
    );

    test(
      '$kind chosen work time survives refresh and storage round trip',
      () async {
        final event = await import(kind);
        final start = DateTime(2030, 1, 3, 14);
        final moved = resizeEvent(
          shiftEvent(event, start),
          null,
          start.add(const Duration(minutes: 90)),
        ).copyWith(done: true, completedAt: start, timerStartedAt: start);
        expect(moved.workTimeScheduled, isTrue);
        calendar.updateEvent(PlannerEvent.fromJson(moved.toJson()));
        source = changed;
        await feeds.syncFeed('class');
        final synced = calendar.state.single;
        expect(synced.start, moved.start);
        expect(synced.end, moved.end);
        expect(synced.workTimeScheduled, isTrue);
        expect(synced.done, isTrue);
        expect(synced.timerStartedAt, moved.timerStartedAt);
        expect(synced.completedAt, moved.completedAt);
        expect(synced.subject, 'Updated assignment');
        // A second refresh must retain the scheduling flag as well.
        await feeds.syncFeed('class');
        expect(calendar.state.single.start, moved.start);
      },
    );
  }
}
