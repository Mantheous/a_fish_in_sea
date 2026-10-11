import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../model/planner_event.dart';

/// Reminder offsets offered in the editor and the post-save prompt.
const List<int> eventReminderChoices = [10, 30, 60, 1440];

/// Shorter set used by the "looks like an appointment?" prompt.
const List<int> promptReminderChoices = [15, 60, 1440];

String eventReminderLabel(int minutesBefore) {
  if (minutesBefore < 60) return '$minutesBefore minutes before';
  if (minutesBefore < 1440) {
    final hours = minutesBefore ~/ 60;
    return hours == 1 ? '1 hour before' : '$hours hours before';
  }
  final days = minutesBefore ~/ 1440;
  return days == 1 ? '1 day before' : '$days days before';
}

/// When the notification should fire for [event], or null when it has no
/// reminder or the fire time is not in the future.
DateTime? reminderTimeFor(PlannerEvent event, {DateTime? now}) {
  final minutes = event.reminderMinutesBefore;
  if (minutes == null || minutes <= 0) return null;
  final fireAt = event.start.subtract(Duration(minutes: minutes));
  final at = now ?? DateTime.now();
  if (!fireAt.isAfter(at)) return null;
  return fireAt;
}

int eventNotificationId(String eventId) => eventId.hashCode & 0x7fffffff;

/// Best-effort local notification scheduling for event reminders.
/// All failures are swallowed: reminders are a convenience, never a save
/// blocker. Web has no exact-alarm support here, so it is a no-op there.
class EventReminderService {
  EventReminderService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  static Future<void> ensureInitialized() async {
    if (_initialized || kIsWeb) return;
    try {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          linux: LinuxInitializationSettings(
            defaultActionName: 'Open',
          ),
        ),
      );
      _initialized = true;
    } catch (_) {}
  }

  static Future<void> scheduleReminder(PlannerEvent event) async {
    final minutes = event.reminderMinutesBefore;
    if (minutes == null || minutes <= 0) return;
    if (kIsWeb) return;
    final fireAt = reminderTimeFor(event);
    if (fireAt == null) return;
    try {
      await ensureInitialized();
      await _plugin.zonedSchedule(
        eventNotificationId(event.id),
        event.subject.isEmpty ? 'Upcoming event' : event.subject,
        'Starts ${event.start.hour.toString().padLeft(2, '0')}:'
        '${event.start.minute.toString().padLeft(2, '0')}'
        '${event.location != null && event.location!.isNotEmpty ? ' · ${event.location}' : ''}',
        tz.TZDateTime.from(fireAt, tz.local),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'event_reminders',
            'Event reminders',
            channelDescription: 'Reminders for upcoming appointments',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (_) {}
  }

  static Future<void> cancelReminder(String eventId) async {
    if (kIsWeb) return;
    try {
      await _plugin.cancel(eventNotificationId(eventId));
    } catch (_) {}
  }
}
