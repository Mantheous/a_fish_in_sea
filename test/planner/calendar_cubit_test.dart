import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

void main() {
  late Storage storage;

  setUp(() {
    storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  PlannerEvent event(
    String id,
    DateTime start, {
    String rule = '',
    String? feedId,
  }) =>
      PlannerEvent(
        id: id,
        subject: 'Event $id',
        start: start,
        end: start.add(const Duration(hours: 1)),
        recurrenceRule: rule,
        feedId: feedId,
      );

  group('CalendarCubit', () {
    test('initial state is empty', () {
      final cubit = CalendarCubit();
      expect(cubit.state, isEmpty);
    });

    test('add, update and delete', () {
      final cubit = CalendarCubit();
      final base = event('e1', DateTime(2026, 9, 4, 9));
      cubit.addEvent(base);
      expect(cubit.state.length, 1);
      cubit.updateEvent(
        base.copyWith(subject: 'Renamed'),
      );
      expect(cubit.state.single.subject, 'Renamed');
      cubit.deleteEvent('e1');
      expect(cubit.state, isEmpty);
    });

    test("replaceFeedEvents removes only that feed's events", () {
      final cubit = CalendarCubit();
      cubit.addEvent(event('mine', DateTime(2026, 9, 4, 9)));
      cubit.replaceFeedEvents('f1', [
        event('f1e1', DateTime(2026, 9, 5, 9), feedId: 'f1'),
      ]);
      expect(cubit.state.length, 2);
      cubit.replaceFeedEvents('f1', [
        event('f1e2', DateTime(2026, 9, 6, 9), feedId: 'f1'),
      ]);
      expect(cubit.state.map((e) => e.id), ['mine', 'f1e2']);
      cubit.removeFeedEvents('f1');
      expect(cubit.state.map((e) => e.id), ['mine']);
    });

    test('eventsOnDay finds single and recurring events', () {
      final cubit = CalendarCubit();
      cubit.addEvent(event('single', DateTime(2026, 9, 4, 9)));
      cubit.addEvent(event(
        'recurring',
        DateTime(2026, 9, 1, 10),
        rule: 'FREQ=WEEKLY;BYDAY=FR',
      ));
      cubit.addEvent(event('other', DateTime(2026, 9, 5, 9)));
      final onFriday = cubit.eventsOnDay(DateTime(2026, 9, 4));
      expect(onFriday.map((e) => e.id).toSet(), {'single', 'recurring'});
      final onSaturday = cubit.eventsOnDay(DateTime(2026, 9, 5));
      expect(onSaturday.map((e) => e.id), ['other']);
    });

    test('feedEventsInRange only returns feed events', () {
      final cubit = CalendarCubit();
      cubit.addEvent(event('mine', DateTime(2026, 9, 4, 9)));
      cubit.addEvent(event(
        'hw',
        DateTime(2026, 9, 5, 9),
        feedId: 'f1',
      ));
      final inRange = cubit.feedEventsInRange(
        DateTime(2026, 9, 4),
        DateTime(2026, 9, 6),
      );
      expect(inRange.map((e) => e.id), ['hw']);
    });

    test('serialization round trip', () {
      final cubit = CalendarCubit();
      cubit.addEvent(event(
        'recurring',
        DateTime(2026, 9, 1, 10),
        rule: 'FREQ=WEEKLY;BYDAY=FR',
      ));
      final restored = cubit.fromJson(cubit.toJson(cubit.state));
      expect(restored, cubit.state);
    });
  });
}
