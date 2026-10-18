import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/reporting/service/day_plan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

class MockGoogle extends Mock implements GoogleCalendarService {}

class CountingCalendar extends CalendarCubit {
  var occurrenceExpansions = 0;

  @override
  List<DateTime> occurrencesOf(
    PlannerEvent event,
    DateTime windowStart,
    DateTime windowEnd,
  ) {
    occurrenceExpansions++;
    return super.occurrencesOf(event, windowStart, windowEnd);
  }
}

void main() {
  late CountingCalendar calendar;
  late FeedCubit feeds;
  late NodeCubit nodes;
  late UndoCubit undo;
  final day = DateTime(2026, 10, 18);
  const feed = Feed(id: 'f1', name: 'Classes', url: '');

  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    undo = UndoCubit();
    calendar = CountingCalendar();
    nodes = NodeCubit();
    feeds = FeedCubit(
      calendarCubit: calendar,
      nodeCubit: nodes,
      icalService: IcalService(),
      googleService: MockGoogle(),
      proxyBase: () => '',
    );
    feeds.addFeed(feed);
    calendar.addEvent(
      PlannerEvent(
        id: 'recurring',
        subject: 'Class',
        start: day.add(const Duration(hours: 9)),
        end: day.add(const Duration(hours: 10)),
        recurrenceRule: 'FREQ=DAILY;COUNT=40',
        feedId: feed.id,
      ),
    );
  });

  tearDown(() async {
    await feeds.close();
    await calendar.close();
    await nodes.close();
    await undo.close();
  });

  test('same day reuses slices without repeating recurrence expansion', () {
    final first = daySlices(calendar, feeds, day);
    final expansions = calendar.occurrenceExpansions;
    expect(first.single.title, 'Class');
    for (var i = 0; i < 100; i++) {
      expect(
        identical(
          daySlices(calendar, feeds, day.add(Duration(minutes: i))),
          first,
        ),
        isTrue,
      );
    }
    expect(calendar.occurrenceExpansions, expansions);
    expect(() => first.clear(), throwsUnsupportedError);
  });

  test('event edit, undo and redo invalidate planned slices', () {
    final first = daySlices(calendar, feeds, day);
    calendar.updateEvent(calendar.state.single.copyWith(subject: 'Updated'));
    expect(daySlices(calendar, feeds, day).single.title, 'Updated');
    undo.undo();
    final restored = daySlices(calendar, feeds, day);
    expect(restored.single.title, first.single.title);
    undo.redo();
    expect(daySlices(calendar, feeds, day).single.title, 'Updated');
  });

  test('feed visibility changes invalidate slices', () {
    expect(daySlices(calendar, feeds, day), hasLength(1));
    feeds.updateFeed(feed.copyWith(enabled: false));
    expect(daySlices(calendar, feeds, day), isEmpty);
    undo.undo();
    expect(daySlices(calendar, feeds, day), hasLength(1));
  });

  test('switching days retains each recurrence date and bounds the cache', () {
    final first = daySlices(calendar, feeds, day);
    final next = daySlices(calendar, feeds, day.add(const Duration(days: 1)));
    expect(next.single.start, day.add(const Duration(days: 1, hours: 9)));
    expect(identical(daySlices(calendar, feeds, day), first), isTrue);
    for (var i = 2; i < 32; i++) {
      daySlices(calendar, feeds, DateTime(day.year, day.month, day.day + i));
    }
    expect(identical(daySlices(calendar, feeds, day), first), isFalse);
  });
}
