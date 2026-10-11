import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/event_reminders.dart';
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

  group('eventReminderLabel', () {
    test('formats minutes, hours, and days', () {
      expect(eventReminderLabel(10), '10 minutes before');
      expect(eventReminderLabel(30), '30 minutes before');
      expect(eventReminderLabel(60), '1 hour before');
      expect(eventReminderLabel(120), '2 hours before');
      expect(eventReminderLabel(1440), '1 day before');
      expect(eventReminderLabel(2880), '2 days before');
    });
  });

  group('reminderTimeFor', () {
    final start = DateTime(2026, 10, 20, 10);
    final now = DateTime(2026, 10, 19, 9);

    PlannerEvent eventWith(int? reminder) => PlannerEvent(
          id: 'e1',
          subject: 'Doctor appointment',
          start: start,
          end: start.add(const Duration(hours: 1)),
          reminderMinutesBefore: reminder,
        );

    test('subtracts the offset from the start', () {
      expect(
        reminderTimeFor(eventWith(30), now: now),
        start.subtract(const Duration(minutes: 30)),
      );
    });

    test('null when no reminder or fire time has passed', () {
      expect(reminderTimeFor(eventWith(null), now: now), isNull);
      expect(reminderTimeFor(eventWith(0), now: now), isNull);
      expect(
        reminderTimeFor(
          eventWith(30),
          now: start.subtract(const Duration(minutes: 29)),
        ),
        isNull,
      );
    });
  });

  group('PlannerEvent reminder persistence', () {
    test('round-trips the reminder', () {
      final start = DateTime(2026, 10, 20, 10);
      final event = PlannerEvent(
        id: 'e1',
        subject: 'Doctor appointment',
        start: start,
        end: start.add(const Duration(hours: 1)),
        reminderMinutesBefore: 30,
      );
      expect(PlannerEvent.fromJson(event.toJson()), event);
      expect(event.hasReminder, isTrue);
    });

    test('legacy payloads without a reminder default to null', () {
      final start = DateTime(2026, 10, 20, 10);
      final json = PlannerEvent(
        id: 'old',
        subject: 'Lecture',
        start: start,
        end: start.add(const Duration(hours: 1)),
      ).toJson()
        ..remove('reminderMinutesBefore');
      final restored = PlannerEvent.fromJson(json);
      expect(restored.reminderMinutesBefore, isNull);
      expect(restored.hasReminder, isFalse);
    });

    test('corrupt reminder values fall back to null', () {
      final start = DateTime(2026, 10, 20, 10);
      for (final bad in ['soon', -5, 0, '']) {
        final json = PlannerEvent(
          id: 'bad',
          subject: 'Lecture',
          start: start,
          end: start.add(const Duration(hours: 1)),
        ).toJson()
          ..['reminderMinutesBefore'] = bad;
        expect(
          PlannerEvent.fromJson(json).reminderMinutesBefore,
          isNull,
          reason: 'raw=$bad',
        );
      }
    });

    test('CalendarCubit keeps reminders across toJson/fromJson', () {
      final cubit = CalendarCubit();
      final start = DateTime(2026, 10, 20, 10);
      cubit.addEvent(PlannerEvent(
        id: 'e1',
        subject: 'Doctor appointment',
        start: start,
        end: start.add(const Duration(hours: 1)),
        reminderMinutesBefore: 60,
      ));
      final restored = cubit.fromJson(cubit.toJson(cubit.state));
      expect(restored?.single.reminderMinutesBefore, 60);
    });

    test('copyWith can set and clear the reminder', () {
      final start = DateTime(2026, 10, 20, 10);
      final base = PlannerEvent(
        id: 'e1',
        subject: 'Visit',
        start: start,
        end: start.add(const Duration(hours: 1)),
      );
      expect(
        base.copyWith(reminderMinutesBefore: 15).reminderMinutesBefore,
        15,
      );
      expect(
        base
            .copyWith(reminderMinutesBefore: 15)
            .copyWith(clearReminder: true)
            .reminderMinutesBefore,
        isNull,
      );
    });
  });
}
