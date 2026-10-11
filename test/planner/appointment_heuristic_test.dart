import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/model/task_assignee.dart';
import 'package:a_fish_in_sea/planner/service/appointment_heuristic.dart';
import 'package:flutter_test/flutter_test.dart';

PlannerEvent appointment({
  required String subject,
  String rule = '',
  bool allDay = false,
  String? location,
  String? placeId,
  int people = 0,
  int? reminder,
  DateTime? start,
}) {
  final at = start ?? DateTime(2026, 10, 20, 10);
  return PlannerEvent(
    id: 'e:${subject.hashCode}',
    subject: subject,
    location: location,
    placeId: placeId,
    start: at,
    end: at.add(const Duration(hours: 1)),
    allDay: allDay,
    recurrenceRule: rule,
    assignees: List.generate(
      people,
      (i) => TaskAssigneeX.fake(i),
    ),
    reminderMinutesBefore: reminder,
  );
}

// Minimal stand-in helper for attendees.
extension TaskAssigneeX on TaskAssignee {
  static TaskAssignee fake(int i) =>
      TaskAssignee(id: 'people/$i', displayName: 'Person $i');
}

void main() {
  group('eventLooksLikeAppointment', () {
    test('repeating events never prompt', () {
      expect(
        eventLooksLikeAppointment(appointment(
          subject: 'Doctor appointment',
          rule: 'FREQ=WEEKLY;BYDAY=MO',
        )),
        isFalse,
      );
    });

    test('all-day events never prompt', () {
      expect(
        eventLooksLikeAppointment(appointment(
          subject: 'Doctor appointment',
          allDay: true,
        )),
        isFalse,
      );
    });

    test('location, people, or place signal an appointment', () {
      expect(
        eventLooksLikeAppointment(
            appointment(subject: 'Catch up', location: 'Clinic')),
        isTrue,
      );
      expect(
        eventLooksLikeAppointment(
            appointment(subject: 'Catch up', people: 1)),
        isTrue,
      );
      expect(
        eventLooksLikeAppointment(
            appointment(subject: 'Catch up', placeId: 'clinic')),
        isTrue,
      );
    });

    test('appointment keywords prompt', () {
      for (final title in [
        'Doctor appointment',
        'Dentist checkup',
        'Job interview',
        'Meeting with team',
        'Lunch with Sam',
        'Haircut',
        'Therapy session',
      ]) {
        expect(
          eventLooksLikeAppointment(appointment(subject: title)),
          isTrue,
          reason: title,
        );
      }
    });

    test('plain chores do not prompt', () {
      for (final title in [
        'Clean the kitchen',
        'Do laundry',
        'Take out trash',
        'Buy groceries',
        'Water plants',
        '',
      ]) {
        expect(
          eventLooksLikeAppointment(appointment(subject: title)),
          isFalse,
          reason: title,
        );
      }
    });
  });

  group('shouldPromptForReminder', () {
    final now = DateTime(2026, 10, 1, 9);

    test('prompts for future appointment-like events without a reminder',
        () {
      expect(
        shouldPromptForReminder(
          appointment(
            subject: 'Doctor appointment',
            start: now.add(const Duration(days: 2)),
          ),
          now: now,
        ),
        isTrue,
      );
    });

    test('no prompt when a reminder is already set', () {
      expect(
        shouldPromptForReminder(
          appointment(
            subject: 'Doctor appointment',
            start: now.add(const Duration(days: 2)),
            reminder: 30,
          ),
          now: now,
        ),
        isFalse,
      );
    });

    test('no prompt for past events', () {
      expect(
        shouldPromptForReminder(
          appointment(
            subject: 'Doctor appointment',
            start: now.subtract(const Duration(days: 1)),
          ),
          now: now,
        ),
        isFalse,
      );
    });

    test('no prompt for chores or repeating events', () {
      expect(
        shouldPromptForReminder(
          appointment(
            subject: 'Do laundry',
            start: now.add(const Duration(days: 1)),
          ),
          now: now,
        ),
        isFalse,
      );
      expect(
        shouldPromptForReminder(
          appointment(
            subject: 'Doctor appointment',
            rule: 'FREQ=DAILY',
            start: now.add(const Duration(days: 1)),
          ),
          now: now,
        ),
        isFalse,
      );
    });
  });
}
