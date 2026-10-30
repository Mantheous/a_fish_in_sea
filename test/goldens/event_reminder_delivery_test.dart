import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/event_reminders.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  tz.initializeTimeZones();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');

  for (final scenario in [
    'initialization fails',
    'granted',
    'notifications denied',
    'exact access denied',
    'exact access already granted',
    'scheduling fails',
    'expired',
    'no reminder',
  ]) {
    testWidgets(scenario, (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        switch (call.method) {
          case 'initialize':
            return scenario != 'initialization fails';
          case 'requestNotificationsPermission':
            return scenario != 'notifications denied';
          case 'canScheduleExactNotifications':
            return scenario == 'exact access already granted';
          case 'requestExactAlarmsPermission':
            return scenario != 'exact access denied';
          case 'zonedSchedule':
            if (scenario == 'scheduling fails') {
              throw PlatformException(code: 'exact_alarms_not_permitted');
            }
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final start = DateTime.now().add(
        Duration(hours: scenario == 'expired' ? -1 : 1),
      );
      final event = PlannerEvent(
        id: 'delivery',
        subject: 'Appointment',
        start: start,
        end: start.add(const Duration(hours: 1)),
        reminderMinutesBefore: scenario == 'no reminder' ? null : 10,
      );
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: EventReminderService.messengerKey,
          home: const Scaffold(body: Text('Calendar')),
        ),
      );
      await EventReminderService.scheduleReminder(event);
      await tester.pumpAndSettle();
      final methods = calls.map((call) => call.method).toList();
      final scheduled = [
        'granted',
        'exact access already granted',
      ].contains(scenario);
      final failed = !scheduled && scenario != 'no reminder';
      expect(
        find.textContaining('Event saved. Reminder not scheduled.'),
        failed ? findsOneWidget : findsNothing,
      );
      expect(
        methods.contains('zonedSchedule'),
        scheduled || scenario == 'scheduling fails',
      );
      if (scheduled) {
        expect(
          methods.indexOf('requestNotificationsPermission'),
          lessThan(methods.indexOf('zonedSchedule')),
        );
        final args = calls.last.arguments as Map;
        expect(
          (args['platformSpecifics'] as Map)['scheduleMode'],
          'exactAllowWhileIdle',
        );
        expect(args['id'], eventNotificationId(event.id));
      }
      if (scenario == 'notifications denied') {
        expect(methods, isNot(contains('requestExactAlarmsPermission')));
        expect(
          find.textContaining('Allow notifications in Android settings'),
          findsOneWidget,
        );
        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile('event_reminder_delivery.notifications_denied.png'),
        );
      }
      if (scenario == 'exact access already granted') {
        expect(methods, isNot(contains('requestExactAlarmsPermission')));
      }
      if (scenario == 'exact access denied') {
        expect(find.textContaining('Allow alarms & reminders'), findsOneWidget);
      }
      if (scenario == 'no reminder') expect(calls, isEmpty);
      // Failed scheduling leaves the event and its chosen offset intact.
      expect(
        event.reminderMinutesBefore,
        scenario == 'no reminder' ? isNull : 10,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
