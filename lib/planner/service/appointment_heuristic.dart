import '../model/planner_event.dart';

/// Heuristic for issue #3: a one-off event that "seems to be an
/// appointment" deserves a nudge asking whether the user wants a reminder.
///
/// Deliberately conservative: repeating events, all-day events, and plain
/// chores never prompt. A timed one-off prompts when it carries an
/// appointment signal — a location, attendees, a saved place, or an
/// appointment-like title.
const List<String> appointmentKeywords = [
  'appointment',
  'meeting',
  'interview',
  'doctor',
  'dentist',
  'clinic',
  'therapy',
  'therapist',
  'vet',
  'court',
  'lawyer',
  'consult',
  'reservation',
  'booking',
  'visit',
  'checkup',
  'check-up',
  'exam',
  'lesson',
  'session',
  'advisor',
  'adviser',
  'landlord',
  'bank',
  'dmv',
  'passport',
  'haircut',
  'massage',
  'call with',
  'lunch with',
  'dinner with',
  'coffee with',
  'breakfast with',
];

final RegExp _withSomeone = RegExp(r'\bwith\s+\S+', caseSensitive: false);

bool titleLooksLikeAppointment(String subject) {
  final lower = subject.toLowerCase();
  if (lower.trim().isEmpty) return false;
  for (final keyword in appointmentKeywords) {
    if (lower.contains(keyword)) return true;
  }
  return _withSomeone.hasMatch(subject);
}

/// Pure core of the heuristic, kept free of the event model so it is easy
/// to unit test from either side.
bool looksLikeAppointment({
  required String subject,
  required String recurrenceRule,
  required bool allDay,
  String? location,
  String? placeId,
  required bool hasPeople,
}) {
  if (recurrenceRule.isNotEmpty) return false;
  if (allDay) return false;
  if (location != null && location.trim().isNotEmpty) return true;
  if (placeId != null && placeId.isNotEmpty) return true;
  if (hasPeople) return true;
  return titleLooksLikeAppointment(subject);
}

bool eventLooksLikeAppointment(PlannerEvent event) => looksLikeAppointment(
      subject: event.subject,
      recurrenceRule: event.recurrenceRule,
      allDay: event.allDay,
      location: event.location,
      placeId: event.placeId,
      hasPeople: event.assignees.isNotEmpty,
    );

/// True when a freshly saved event should trigger the "want a reminder?"
/// prompt: one-off, appointment-like, no reminder yet, and starting in the
/// future (relative to [now]).
bool shouldPromptForReminder(PlannerEvent event, {DateTime? now}) {
  if (event.hasReminder) return false;
  if (!eventLooksLikeAppointment(event)) return false;
  final at = now ?? DateTime.now();
  return event.start.isAfter(at);
}
