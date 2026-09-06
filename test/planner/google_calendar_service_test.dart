import 'dart:convert';

import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

GoogleCalendarService serviceWith(Map<String, http.Response> routes) {
  return GoogleCalendarService(
    baseUrl: () => '',
    userId: () => 'u',
    client: MockClient((request) async {
      return routes[request.url.path] ??
          http.Response('Not found', 404);
    }),
  );
}

Map<String, dynamic> eventJson({
  String id = 'e1',
  String? backgroundColor,
}) =>
    {
      'id': id,
      'summary': 'Work',
      'start': '2026-09-10T12:30:00-06:00',
      'end': '2026-09-10T13:30:00-06:00',
      if (backgroundColor != null) 'backgroundColor': backgroundColor,
    };

void main() {
  group('isoWithOffset', () {
    test('keeps the Z suffix for UTC values', () {
      expect(
        isoWithOffset(DateTime.utc(2026, 9, 10, 12, 30)),
        '2026-09-10T12:30:00.000Z',
      );
    });

    test('appends the offset for local values', () {
      final local = DateTime(2026, 9, 10, 12, 30);
      final offset = local.timeZoneOffset;
      final sign = offset.isNegative ? '-' : '+';
      final abs = offset.abs();
      final expected =
          '2026-09-10T12:30:00.000$sign${abs.inHours.toString().padLeft(2, '0')}:${(abs.inMinutes % 60).toString().padLeft(2, '0')}';
      expect(isoWithOffset(local), expected);
    });
  });

  group('parseCssColor', () {
    test('parses hash-prefixed hex with full opacity', () {
      expect(parseCssColor('#039be5'), 0xFF039BE5);
    });

    test('parses bare and shorthand hex', () {
      expect(parseCssColor('dc2127'), 0xFFDC2127);
      expect(parseCssColor('#fff'), 0xFFFFFFFF);
    });

    test('returns null for missing or malformed values', () {
      expect(parseCssColor(null), isNull);
      expect(parseCssColor(''), isNull);
      expect(parseCssColor('not-a-color'), isNull);
      expect(parseCssColor('#12345'), isNull);
    });
  });

  group('GoogleCalendarService colors', () {
    test('event color wins over the calendar fallback', () async {
      final service = serviceWith({
        '/api/google/events': http.Response(
          jsonEncode({
            'events': [eventJson(backgroundColor: '#dc2127')],
            'calendar': {'backgroundColor': '#9fc6e7'},
          }),
          200,
        ),
      });
      final events = await service.fetchEvents(
        calendarId: 'primary',
        feedId: 'f1',
      );
      expect(events, hasLength(1));
      expect(events.first.colorValue, 0xFFDC2127);
    });

    test('events without their own color inherit the calendar color', () async {
      final service = serviceWith({
        '/api/google/events': http.Response(
          jsonEncode({
            'events': [eventJson()],
            'calendar': {'backgroundColor': '#9fc6e7'},
          }),
          200,
        ),
      });
      final events = await service.fetchEvents(
        calendarId: 'primary',
        feedId: 'f1',
      );
      expect(events.first.colorValue, 0xFF9FC6E7);
    });

    test('missing colors leave colorValue null', () async {
      final service = serviceWith({
        '/api/google/events': http.Response(
          jsonEncode({
            'events': [eventJson()],
          }),
          200,
        ),
      });
      final events = await service.fetchEvents(
        calendarId: 'primary',
        feedId: 'f1',
      );
      expect(events.first.colorValue, isNull);
    });

    test('calendar list exposes the Google calendar color', () async {
      final service = serviceWith({
        '/api/google/calendars': http.Response(
          jsonEncode({
            'calendars': [
              {
                'id': 'primary',
                'summary': 'Work',
                'backgroundColor': '#9fc6e7',
              },
              {'id': 'other', 'summary': 'Other'},
            ],
          }),
          200,
        ),
      });
      final calendars = await service.listCalendars();
      expect(calendars, hasLength(2));
      expect(calendars.first.colorValue, 0xFF9FC6E7);
      expect(calendars.last.colorValue, isNull);
    });
  });

  group('GoogleCalendarService writes', () {
    PlannerEvent localEvent() => PlannerEvent(
          id: 'gcal:f1:e1',
          subject: 'Work',
          notes: 'Bring notes',
          location: 'Room 1',
          start: DateTime(2026, 9, 10, 12, 30),
          end: DateTime(2026, 9, 10, 13, 30),
          feedId: 'f1',
          sourceUid: 'e1',
        );

    test('updateEvent PATCHes and parses the returned event', () async {
      String? capturedBody;
      final service = GoogleCalendarService(
        baseUrl: () => '',
        userId: () => 'u',
        client: MockClient((request) async {
          expect(request.method, 'PATCH');
          expect(request.url.path, '/api/google/events');
          capturedBody = request.body;
          return http.Response(
            jsonEncode({'event': eventJson(id: 'e1')}),
            200,
          );
        }),
      );
      final updated = await service.updateEvent(
        calendarId: 'primary',
        feedId: 'f1',
        eventId: 'e1',
        event: localEvent(),
      );
      expect(updated.id, 'gcal:f1:e1');
      expect(updated.sourceUid, 'e1');
      final body = jsonDecode(capturedBody!) as Map<String, dynamic>;
      expect(body['calendarId'], 'primary');
      expect(body['eventId'], 'e1');
      expect(body['summary'], 'Work');
      expect(body['location'], 'Room 1');
    });

    test('createEvent POSTs the event fields', () async {
      String? capturedMethod;
      final service = GoogleCalendarService(
        baseUrl: () => '',
        userId: () => 'u',
        client: MockClient((request) async {
          capturedMethod = request.method;
          return http.Response(
            jsonEncode({'event': eventJson(id: 'new1')}),
            200,
          );
        }),
      );
      final created = await service.createEvent(
        calendarId: 'primary',
        feedId: 'f1',
        event: localEvent(),
      );
      expect(capturedMethod, 'POST');
      expect(created.sourceUid, 'new1');
    });

    test('deleteEvent DELETEs with calendar and event ids', () async {
      String? capturedMethod;
      String? capturedBody;
      final service = GoogleCalendarService(
        baseUrl: () => '',
        userId: () => 'u',
        client: MockClient((request) async {
          capturedMethod = request.method;
          capturedBody = request.body;
          return http.Response(jsonEncode({'deleted': true}), 200);
        }),
      );
      await service.deleteEvent(calendarId: 'primary', eventId: 'e1');
      expect(capturedMethod, 'DELETE');
      final body = jsonDecode(capturedBody!) as Map<String, dynamic>;
      expect(body['eventId'], 'e1');
    });

    test('write failures surface the server message and status', () async {
      final service = serviceWith({
        '/api/google/events': http.Response(
          jsonEncode({
            'error': 'Google denied this change',
            'needsReconnect': true,
          }),
          403,
        ),
      });
      try {
        await service.updateEvent(
          calendarId: 'primary',
          feedId: 'f1',
          eventId: 'e1',
          event: localEvent(),
        );
        fail('expected a GoogleCalendarException');
      } on GoogleCalendarException catch (e) {
        expect(e.statusCode, 403);
        expect(e.needsReconnect, isTrue);
        expect(e.message, contains('denied'));
      }
    });

    test('calendar list exposes write access', () async {
      final service = serviceWith({
        '/api/google/calendars': http.Response(
          jsonEncode({
            'calendars': [
              {'id': 'a', 'summary': 'A', 'accessRole': 'writer'},
              {'id': 'b', 'summary': 'B', 'accessRole': 'reader'},
              {'id': 'c', 'summary': 'C'},
            ],
          }),
          200,
        ),
      });
      final calendars = await service.listCalendars();
      expect(calendars[0].canWrite, isTrue);
      expect(calendars[1].canWrite, isFalse);
      expect(calendars[2].canWrite, isFalse);
    });
  });
  group('GoogleCalendarService recurrence', () {
    test('parseRecurrenceRule extracts the bare RRULE', () {
      expect(
        parseRecurrenceRule(['RRULE:FREQ=WEEKLY;BYDAY=MO,WE']),
        'FREQ=WEEKLY;BYDAY=MO,WE',
      );
      expect(parseRecurrenceRule([]), '');
      expect(parseRecurrenceRule(null), '');
      expect(parseRecurrenceRule(['EXDATE:20260910T123000Z']), '');
    });

    test('fetchEvents keeps the series id and rule', () async {
      final service = serviceWith({
        '/api/google/events': http.Response(
          jsonEncode({
            'events': [
              {
                ...eventJson(id: 'ev1_20260910T123000Z'),
                'recurrence': ['RRULE:FREQ=WEEKLY;BYDAY=WE'],
                'seriesId': 'ev1',
              },
            ],
          }),
          200,
        ),
      });
      final events = await service.fetchEvents(
        calendarId: 'primary',
        feedId: 'f1',
      );
      expect(events.single.recurrenceRule, 'FREQ=WEEKLY;BYDAY=WE');
      expect(events.single.seriesId, 'ev1');
      expect(events.single.isRecurringInstance, isTrue);
    });

    test('updateEvent sends recurrence for series edits', () async {
      Map<String, dynamic>? capturedBody;
      final service = GoogleCalendarService(
        baseUrl: () => '',
        userId: () => 'u',
        client: MockClient((request) async {
          capturedBody =
              jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({'event': eventJson(id: 'ev1')}),
            200,
          );
        }),
      );
      await service.updateEvent(
        calendarId: 'primary',
        feedId: 'f1',
        eventId: 'ev1',
        event: PlannerEvent(
          id: 'gcal:f1:ev1',
          subject: 'Standup',
          start: DateTime(2026, 9, 2, 12, 30),
          end: DateTime(2026, 9, 2, 13, 30),
          feedId: 'f1',
          sourceUid: 'ev1',
          recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO,WE,FR',
        ),
      );
      expect(
        capturedBody!['recurrence'],
        ['RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR'],
      );
    });

    test('updateEvent omits recurrence for instance edits', () async {
      Map<String, dynamic>? capturedBody;
      final service = GoogleCalendarService(
        baseUrl: () => '',
        userId: () => 'u',
        client: MockClient((request) async {
          capturedBody =
              jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({'event': eventJson(id: 'x')}),
            200,
          );
        }),
      );
      await service.updateEvent(
        calendarId: 'primary',
        feedId: 'f1',
        eventId: 'ev1_20260910T123000Z',
        event: PlannerEvent(
          id: 'gcal:f1:ev1_20260910T123000Z',
          subject: 'Standup',
          start: DateTime(2026, 9, 10, 14, 30),
          end: DateTime(2026, 9, 10, 15, 30),
          feedId: 'f1',
          sourceUid: 'ev1_20260910T123000Z',
          seriesId: 'ev1',
          recurrenceRule: 'FREQ=WEEKLY;BYDAY=WE',
        ),
        instanceEdit: true,
      );
      expect(capturedBody!.containsKey('recurrence'), isFalse);
    });

    test('fetchEvent parses a series master', () async {
      final service = serviceWith({
        '/api/google/events/one': http.Response(
          jsonEncode({
            'event': {
              ...eventJson(id: 'ev1'),
              'recurrence': ['RRULE:FREQ=DAILY'],
            },
          }),
          200,
        ),
      });
      final master = await service.fetchEvent(
        calendarId: 'primary',
        feedId: 'f1',
        eventId: 'ev1',
      );
      expect(master.sourceUid, 'ev1');
      expect(master.recurrenceRule, 'FREQ=DAILY');
    });
  });
  group('PlannerEvent colorValue', () {
    test('seriesId round trips through json', () {
      final event = PlannerEvent(
        id: 'gcal:f1:ev1_x',
        subject: 'Standup',
        start: DateTime(2026, 9, 10, 12, 30),
        end: DateTime(2026, 9, 10, 13, 30),
        feedId: 'f1',
        sourceUid: 'ev1_x',
        seriesId: 'ev1',
      );
      expect(PlannerEvent.fromJson(event.toJson()), event);
    });

    test('toJson/fromJson round trip preserves the color', () {
      final event = PlannerEvent(
        id: 'gcal:f1:e1',
        subject: 'Work',
        start: DateTime(2026, 9, 10, 12, 30),
        end: DateTime(2026, 9, 10, 13, 30),
        feedId: 'f1',
        sourceUid: 'e1',
        colorValue: 0xFFDC2127,
      );
      final roundTripped = PlannerEvent.fromJson(event.toJson());
      expect(roundTripped.colorValue, 0xFFDC2127);
      expect(roundTripped, event);
    });

    test('copyWith preserves the color by default', () {
      final event = PlannerEvent(
        id: 'gcal:f1:e1',
        subject: 'Work',
        start: DateTime(2026, 9, 10, 12, 30),
        end: DateTime(2026, 9, 10, 13, 30),
        colorValue: 0xFFDC2127,
      );
      expect(event.copyWith(subject: 'Play').colorValue, 0xFFDC2127);
      expect(
        event.copyWith(clearColorValue: true).colorValue,
        isNull,
      );
    });
  });
}
