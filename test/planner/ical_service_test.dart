import 'dart:convert';
import 'dart:typed_data';

import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

class MockClient extends Mock implements http.Client {}

const singleEventIcs = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:assignment-1
DTSTAMP:20260901T120000Z
DTSTART:20260910T090000Z
DTEND:20260910T091500Z
SUMMARY:Reading Quiz 1
DESCRIPTION:Chapters 1-2
LOCATION:TEST
END:VEVENT
END:VCALENDAR
''';

const allDayEventIcs = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:assignment-2
DTSTAMP:20260901T120000Z
DTSTART;VALUE=DATE:20260911
SUMMARY:Paper due
END:VEVENT
END:VCALENDAR
''';

const tzEventIcs = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:assignment-3
DTSTAMP:20260901T120000Z
DTSTART;TZID=America/New_York:20260910T090000
SUMMARY:Studio session
END:VEVENT
END:VCALENDAR
''';

const weeklyRecurringIcs = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:class-1
DTSTAMP:20260901T120000Z
DTSTART:20260907T100000Z
DTEND:20260907T111500Z
SUMMARY:MWF Lecture
RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR
END:VEVENT
END:VCALENDAR
''';

const unsupportedRecurringIcs = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:class-2
DTSTAMP:20260901T120000Z
DTSTART:20260907T100000Z
DTEND:20260907T111500Z
SUMMARY:Exotic rule
RRULE:FREQ=MONTHLY;BYDAY=1MO
END:VEVENT
END:VCALENDAR
''';

const todoIcs = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VTODO
UID:task-1
DTSTAMP:20260901T120000Z
DUE:20260912T170000Z
SUMMARY:Submit lab report
END:VTODO
BEGIN:VTODO
UID:task-2
DTSTAMP:20260901T120000Z
DUE:20260913T170000Z
STATUS:COMPLETED
SUMMARY:Done thing
END:VTODO
END:VCALENDAR
''';

const durationEventIcs = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:class-3
DTSTAMP:20260901T120000Z
DTSTART:20260907T100000Z
DURATION:PT1H15M
SUMMARY:With duration
END:VEVENT
END:VCALENDAR
''';

// Snippets copied from a real Canvas user feed (byu.instructure.com).
const canvasAssignmentIcs = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:icalendar-ruby
CALSCALE:GREGORIAN
METHOD:PUBLISH
BEGIN:VEVENT
DTSTAMP:20260904T060000Z
UID:event-assignment-1477978
DTSTART;VALUE=DATE;VALUE=DATE:20260904
CLASS:PUBLIC
DESCRIPTION:
SEQUENCE:0
SUMMARY:Exit Quiz [STAT 230-002]
URL;VALUE=URI:https://byu.instructure.com/calendar
END:VEVENT
BEGIN:VEVENT
DTSTAMP:20260904T140000Z
UID:event-assignment-1478022
DTSTART:20260904T230000Z
DTEND:20260904T230000Z
CLASS:PUBLIC
SUMMARY:In Class MWF Sep 04 [STAT 230-002]
END:VEVENT
END:VCALENDAR
''';

const cancelledEventIcs = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//Test//EN
BEGIN:VEVENT
UID:cancelled-1
DTSTAMP:20260901T120000Z
DTSTART;VALUE=DATE:20260911
SUMMARY:Old topic
STATUS:CANCELLED
END:VEVENT
BEGIN:VEVENT
UID:live-1
DTSTAMP:20260901T120000Z
DTSTART;VALUE=DATE:20260911
SUMMARY:Quiz 6
END:VEVENT
END:VCALENDAR
''';

const canvasNoCourseIcs = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:icalendar-ruby
BEGIN:VEVENT
DTSTAMP:20260904T060000Z
UID:event-1
DTSTART;VALUE=DATE:20260904
SUMMARY:No course tag here
END:VEVENT
END:VCALENDAR
''';

void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
  });

  group('IcalService.parseIcs', () {
    late IcalService service;

    setUp(() {
      service = IcalService();
    });

    test('parses a timed event', () {
      final events = service.parseIcs(singleEventIcs, feedId: 'f1');
      expect(events.length, 1);
      final event = events.single;
      expect(event.id, 'hw:f1:assignment-1');
      expect(event.subject, 'Reading Quiz 1');
      expect(event.notes, 'Chapters 1-2');
      expect(event.location, 'TEST');
      expect(event.allDay, isFalse);
      expect(event.recurrenceRule, isEmpty);
      expect(
        event.start.toUtc(),
        DateTime.utc(2026, 9, 10, 9, 0),
      );
      expect(
        event.end.toUtc(),
        DateTime.utc(2026, 9, 10, 9, 15),
      );
    });

    test('parses an all-day event', () {
      final events = service.parseIcs(allDayEventIcs, feedId: 'f1');
      final event = events.single;
      expect(event.allDay, isTrue);
      expect(event.subject, 'Paper due');
      expect(
        event.start,
        DateTime(2026, 9, 11),
      );
      expect(
        event.end,
        DateTime(2026, 9, 12),
      );
    });

    test('converts TZID times to the local zone instant', () {
      final events = service.parseIcs(tzEventIcs, feedId: 'f1');
      final event = events.single;
      final location = tz.getLocation('America/New_York');
      final expected = tz.TZDateTime.from(
        DateTime(2026, 9, 10, 9),
        location,
      ).toUtc();
      expect(event.start.toUtc(), expected);
    });

    test('maps weekly RRULE to a canonical rule', () {
      final events = service.parseIcs(weeklyRecurringIcs, feedId: 'f1');
      final event = events.single;
      expect(event.recurrenceRule, 'FREQ=WEEKLY;BYDAY=MO,WE,FR');
    });

    test('falls back to a single occurrence for exotic RRULEs', () {
      final events = service.parseIcs(unsupportedRecurringIcs, feedId: 'f1');
      final event = events.single;
      expect(event.recurrenceRule, isEmpty);
    });

    test('parses VTODOs as events and skips completed ones', () {
      final events = service.parseIcs(todoIcs, feedId: 'f1');
      expect(events.length, 1);
      expect(events.single.subject, 'Submit lab report');
      expect(events.single.start.toUtc(), DateTime.utc(2026, 9, 12, 17));
    });

    test('skips cancelled VEVENTs', () {
      final events = service.parseIcs(cancelledEventIcs, feedId: 'f1');
      expect(events.length, 1);
      expect(events.single.subject, 'Quiz 6');
    });

    test('uses DURATION when DTEND is missing', () {
      final events = service.parseIcs(durationEventIcs, feedId: 'f1');
      final event = events.single;
      expect(
        event.end.toUtc(),
        DateTime.utc(2026, 9, 7, 11, 15),
      );
    });

    test('canvas feeds split the course code into classLabel', () {
      final events = service.parseIcs(
        canvasAssignmentIcs,
        feedId: 'f1',
        kind: FeedKind.canvas,
      );
      expect(events.length, 2);
      final assignment = events.firstWhere(
        (e) => e.subject == 'Exit Quiz',
      );
      expect(assignment.classLabel, 'STAT 230-002');
      expect(assignment.allDay, isTrue);
      expect(assignment.start, DateTime(2026, 9, 4));
      expect(assignment.sourceUid, 'event-assignment-1477978');
      final classSession = events.firstWhere(
        (e) => e.subject == 'In Class MWF Sep 04',
      );
      expect(classSession.classLabel, 'STAT 230-002');
      expect(classSession.allDay, isFalse);
    });

    test('non-canvas feeds keep the full title', () {
      final events = service.parseIcs(
        canvasAssignmentIcs,
        feedId: 'f1',
        kind: FeedKind.learningSuite,
      );
      expect(events.first.subject, 'Exit Quiz [STAT 230-002]');
      expect(events.first.classLabel, isNull);
    });

    test('canvas titles without a course tag are untouched', () {
      final events = service.parseIcs(
        canvasNoCourseIcs,
        feedId: 'f1',
        kind: FeedKind.canvas,
      );
      expect(events.single.subject, 'No course tag here');
      expect(events.single.classLabel, isNull);
    });
  });

  group('IcalService.fetchIcs', () {
    late MockClient client;
    late IcalService service;

    setUp(() {
      client = MockClient();
      service = IcalService(client: client);
      registerFallbackValue(Uri.parse('https://example.com/calendar.ics'));
    });

    test('fetches the ics body on success', () async {
      when(() => client.get(any()))
          .thenAnswer((_) async => http.Response(singleEventIcs, 200));
      final body = await service.fetchIcs(
        url: 'https://example.com/calendar.ics',
        proxyBase: () => 'http://localhost:8000',
      );
      expect(body, singleEventIcs);
      final uri = verify(() => client.get(captureAny()))
          .captured
          .first as Uri;
      expect(uri.host, 'example.com');
    });

    test('tolerates malformed UTF-8 bytes in the feed', () async {
      // Learning Suite declares charset=utf-8 but serves stray bytes
      // (e.g. a truncated multi-byte sequence in "Zitkála-Šá").
      final malformed = Uint8List.fromList([
        ...utf8.encode(
          'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:x\nDTSTAMP:20260901T120000Z\n'
          'DTSTART;VALUE=DATE:20260911\nSUMMARY:Zitk',
        ),
        0xc5,
        ...utf8.encode('la\nEND:VEVENT\nEND:VCALENDAR\n'),
      ]);
      when(() => client.get(any()))
          .thenAnswer((_) async => http.Response.bytes(malformed, 200));
      final body = await service.fetchIcs(
        url: 'https://example.com/calendar.ics',
        proxyBase: () => 'http://localhost:8000',
      );
      expect(body.contains('BEGIN:VCALENDAR'), isTrue);
      final events = service.parseIcs(body, feedId: 'f1');
      expect(events.length, 1);
    });

    test('throws on non-200 responses', () async {
      when(() => client.get(any()))
          .thenAnswer((_) async => http.Response('nope', 404));
      expect(
        () => service.fetchIcs(
          url: 'https://example.com/calendar.ics',
          proxyBase: () => 'http://localhost:8000',
        ),
        throwsA(isA<IcalFetchException>()),
      );
    });

    test('throws when the response is not an iCal file', () async {
      when(() => client.get(any()))
          .thenAnswer((_) async => http.Response('<html>login</html>', 200));
      expect(
        () => service.fetchIcs(
          url: 'https://example.com/calendar.ics',
          proxyBase: () => 'http://localhost:8000',
        ),
        throwsA(isA<IcalFetchException>()),
      );
    });
  });
}
