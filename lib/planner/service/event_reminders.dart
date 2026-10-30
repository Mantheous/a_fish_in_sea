import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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

/// Local reminders never block saving an event. Scheduling failures are
/// shown through the app messenger, including after the editor closes.
/// Web has no local notification support here, so it is a no-op there.
class EventReminderService {
  EventReminderService._();

  static final messengerKey = GlobalKey<ScaffoldMessengerState>();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  static Future<void> ensureInitialized() async {
    if (_initialized || kIsWeb) return;
    final initialized = await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
      ),
    );
    if (initialized != true) throw StateError('Reminder initialization failed');
    _initialized = true;
  }

  static Future<void> scheduleReminder(PlannerEvent event) async {
    final minutes = event.reminderMinutesBefore;
    if (minutes == null || minutes <= 0) return;
    if (kIsWeb) return;
    try {
      await ensureInitialized();
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android != null) {
        if (await android.requestNotificationsPermission() != true) {
          _warn(
            'Allow notifications in Android settings, then save the event again.',
          );
          return;
        }
        if (await android.canScheduleExactNotifications() != true &&
            await android.requestExactAlarmsPermission() != true) {
          _warn(
            'Allow alarms & reminders in Android settings, then save the event again.',
          );
          return;
        }
      }
      // Permission dialogs may stay open until after the reminder time.
      final fireAt = reminderTimeFor(event);
      if (fireAt == null) {
        _warn('Choose a reminder time that is still in the future.');
        return;
      }
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
    } catch (_) {
      _warn(
        'Could not schedule the reminder. Please try saving the event again.',
      );
    }
  }

  static void _warn(String reason) {
    messengerKey.currentState?.showSnackBar(
      SnackBar(content: Text('Event saved. Reminder not scheduled. $reason')),
    );
  }

  static Future<void> cancelReminder(String eventId) async {
    if (kIsWeb) return;
    try {
      await _plugin.cancel(eventNotificationId(eventId));
    } catch (_) {}
  }
}
