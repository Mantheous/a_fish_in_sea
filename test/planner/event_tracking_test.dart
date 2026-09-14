import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/event_tracking.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

PlannerEvent event(String id, DateTime start, {Duration length = const Duration(hours: 1)}) =>
    PlannerEvent(id: id, subject: 'Event $id', start: start, end: start.add(length));

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

  group('PlannerEvent tracking fields', () {
    test('round trip preserves reported + timer + failed', () {
      final base = event('e1', DateTime(2026, 9, 7, 9));
      final tracked = base.copyWith(
        actualStart: DateTime(2026, 9, 7, 9, 5),
        actualEnd: DateTime(2026, 9, 7, 9, 50),
        failed: true,
      );
      expect(PlannerEvent.fromJson(tracked.toJson()), tracked);
      final running = base.copyWith(timerStartedAt: DateTime(2026, 9, 7, 9, 2));
      expect(running.isTracking, isTrue);
      expect(PlannerEvent.fromJson(running.toJson()), running);
    });

    test('old payloads without tracking keys still load', () {
      final json = event('e1', DateTime(2026, 9, 7, 9)).toJson()
        ..remove('actualStart')
        ..remove('actualEnd')
        ..remove('timerStartedAt')
        ..remove('failed');
      final restored = PlannerEvent.fromJson(json);
      expect(restored.actualStart, isNull);
      expect(restored.actualEnd, isNull);
      expect(restored.timerStartedAt, isNull);
      expect(restored.failed, isFalse);
      expect(restored.isTracking, isFalse);
      expect(restored.hasReported, isFalse);
    });

    test('corrupt tracking dates do not drop the event', () {
      final json = event('e1', DateTime(2026, 9, 7, 9)).toJson()
        ..['actualStart'] = 'not-a-date'
        ..['timerStartedAt'] = 'also-bad';
      final restored = PlannerEvent.fromJson(json);
      expect(restored.id, 'e1');
      expect(restored.actualStart, isNull);
      expect(restored.timerStartedAt, isNull);
    });
  });

  group('CalendarCubit tracking', () {
    test('start then stop saves reported interval', () {
      final cubit = CalendarCubit();
      cubit.addEvent(event('e1', DateTime(2026, 9, 7, 9)));
      final t0 = DateTime(2026, 9, 7, 9, 2);
      cubit.startTracking('e1', now: t0);
      expect(cubit.byId('e1')?.isTracking, isTrue);
      expect(cubit.byId('e1')?.timerStartedAt, t0);
      final t1 = DateTime(2026, 9, 7, 9, 47);
      cubit.stopTracking('e1', now: t1);
      final done = cubit.byId('e1')!;
      expect(done.isTracking, isFalse);
      expect(done.actualStart, t0);
      expect(done.actualEnd, t1);
      expect(done.reportedDuration, const Duration(minutes: 45));
    });

    test('starting a second timer saves the first', () {
      final cubit = CalendarCubit();
      cubit.addEvent(event('e1', DateTime(2026, 9, 7, 9)));
      cubit.addEvent(event('e2', DateTime(2026, 9, 7, 10)));
      cubit.startTracking('e1', now: DateTime(2026, 9, 7, 9, 5));
      cubit.startTracking('e2', now: DateTime(2026, 9, 7, 10, 1));
      expect(cubit.byId('e1')?.isTracking, isFalse);
      expect(cubit.byId('e1')?.hasReported, isTrue);
      expect(cubit.byId('e2')?.isTracking, isTrue);
      expect(cubit.activeTrackingId, 'e2');
    });

    test('all-day events cannot be tracked', () {
      final cubit = CalendarCubit();
      cubit.addEvent(PlannerEvent(
        id: 'all',
        subject: 'All day',
        start: DateTime(2026, 9, 7),
        end: DateTime(2026, 9, 8),
        allDay: true,
      ));
      cubit.startTracking('all', now: DateTime(2026, 9, 7, 9));
      expect(cubit.byId('all')?.isTracking, isFalse);
      expect(cubit.activeTrackingId, isNull);
    });

    test('mark failed stops timer and toggles', () {
      final cubit = CalendarCubit();
      cubit.addEvent(event('e1', DateTime(2026, 9, 7, 9)));
      cubit.startTracking('e1', now: DateTime(2026, 9, 7, 9, 5));
      cubit.setFailed('e1', true, now: DateTime(2026, 9, 7, 9, 6));
      final failed = cubit.byId('e1')!;
      expect(failed.failed, isTrue);
      expect(failed.isTracking, isFalse);
      expect(failed.hasReported, isTrue);
      cubit.setFailed('e1', false);
      expect(cubit.byId('e1')?.failed, isFalse);
    });

    test('clearReported resets interval + failed + timer', () {
      final cubit = CalendarCubit();
      cubit.addEvent(event('e1', DateTime(2026, 9, 7, 9)));
      cubit.startTracking('e1', now: DateTime(2026, 9, 7, 9, 5));
      cubit.stopTracking('e1', now: DateTime(2026, 9, 7, 9, 30));
      cubit.setFailed('e1', true);
      cubit.clearReported('e1');
      final cleared = cubit.byId('e1')!;
      expect(cleared.hasReported, isFalse);
      expect(cleared.failed, isFalse);
      expect(cleared.isTracking, isFalse);
    });

    test('tracking survives json round trip', () {
      final cubit = CalendarCubit();
      cubit.addEvent(event('e1', DateTime(2026, 9, 7, 9)));
      cubit.startTracking('e1', now: DateTime(2026, 9, 7, 9, 5));
      final restored = cubit.fromJson(cubit.toJson(cubit.state));
      expect(restored?.single.isTracking, isTrue);
    });
  });

  group('selectNowNext', () {
    test('splits current, previous and next', () {
      final now = DateTime(2026, 9, 7, 10, 30);
      final slices = [
        TrackedSlice(
            event: event('prev', DateTime(2026, 9, 7, 8)),
            start: DateTime(2026, 9, 7, 8),
            end: DateTime(2026, 9, 7, 9)),
        TrackedSlice(
            event: event('now', DateTime(2026, 9, 7, 10)),
            start: DateTime(2026, 9, 7, 10),
            end: DateTime(2026, 9, 7, 11)),
        TrackedSlice(
            event: event('next1', DateTime(2026, 9, 7, 12)),
            start: DateTime(2026, 9, 7, 12),
            end: DateTime(2026, 9, 7, 13)),
        TrackedSlice(
            event: event('next2', DateTime(2026, 9, 7, 14)),
            start: DateTime(2026, 9, 7, 14),
            end: DateTime(2026, 9, 7, 15)),
      ];
      final sel = selectNowNext(slices, now);
      expect(sel.current.map((s) => s.event.id), ['now']);
      expect(sel.previous.map((s) => s.event.id), ['prev']);
      expect(sel.next.map((s) => s.event.id), ['next1', 'next2']);
    });

    test('empty when nothing nearby', () {
      final sel = selectNowNext(const [], DateTime(2026, 9, 7, 10));
      expect(sel.isEmpty, isTrue);
    });
  });

  group('expandTrackedSlices', () {
    test('skips all-day events', () {
      final cubit = CalendarCubit();
      final day = DateTime(2026, 9, 7);
      final allDay = PlannerEvent(
        id: 'all',
        subject: 'All day',
        start: DateTime(2026, 9, 7),
        end: DateTime(2026, 9, 8),
        allDay: true,
      );
      final timed = event('timed', DateTime(2026, 9, 7, 9));
      final out = expandTrackedSlices(
        cubit,
        [allDay, timed],
        day.subtract(const Duration(days: 1)),
        day.add(const Duration(days: 1)),
      );
      expect(out.map((s) => s.event.id), ['timed']);
    });
  });
}
