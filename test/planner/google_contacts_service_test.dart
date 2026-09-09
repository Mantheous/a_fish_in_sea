import 'dart:convert';

import 'package:a_fish_in_sea/planner/service/google_contacts_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

GoogleContactsService serviceWith(Map<String, http.Response> routes) {
  return GoogleContactsService(
    baseUrl: () => '',
    userId: () => 'u',
    client: MockClient((request) async {
      return routes[request.url.path] ?? http.Response('Not found', 404);
    }),
  );
}

void main() {
  group('GoogleContact', () {
    test('fromJson requires an id or name', () {
      expect(
        () => GoogleContact.fromJson({}),
        throwsA(isA<FormatException>()),
      );
    });

    test('email falls back as name and id', () {
      final contact = GoogleContact.fromJson({'email': 'a@test.com'});
      expect(contact.id, 'a@test.com');
      expect(contact.displayName, 'a@test.com');
    });

    test('matchesQuery is case-insensitive over name and email', () {
      const contact = GoogleContact(
        id: 'people/1',
        displayName: 'Ada Lovelace',
        email: 'ada@test.com',
      );
      expect(contact.matchesQuery('ada'), isTrue);
      expect(contact.matchesQuery('LOVE'), isTrue);
      expect(contact.matchesQuery('test.com'), isTrue);
      expect(contact.matchesQuery('grace'), isFalse);
      expect(contact.matchesQuery(''), isTrue);
    });
  });

  group('GoogleContactsService', () {
    test('fetchContacts parses, sorts, and skips malformed entries',
        () async {
      final service = serviceWith({
        '/api/google/contacts': http.Response(
          jsonEncode({
            'contacts': [
              {
                'id': 'people/2',
                'displayName': 'Zed',
                'email': 'zed@test.com',
              },
              {
                'id': 'people/1',
                'displayName': 'Amy',
                'email': 'amy@test.com',
              },
              {'nope': true},
              'not-a-map',
            ],
          }),
          200,
        ),
      });
      final contacts = await service.fetchContacts();
      expect(contacts.map((c) => c.displayName), ['Amy', 'Zed']);
    });

    test('searchCached filters the cached list', () async {
      final service = serviceWith({
        '/api/google/contacts': http.Response(
          jsonEncode({
            'contacts': [
              {'id': 'people/1', 'displayName': 'Amy Pond'},
              {'id': 'people/2', 'displayName': 'Rory Williams'},
            ],
          }),
          200,
        ),
      });
      await service.fetchContacts();
      expect(service.searchCached('amy').map((c) => c.id), ['people/1']);
      expect(service.searchCached('').length, 2);
    });

    test('status exposes contactsGranted', () async {
      final service = serviceWith({
        '/api/google/status': http.Response(
          jsonEncode({'connected': true, 'contactsGranted': false}),
          200,
        ),
      });
      final status = await service.status();
      expect(status.connected, isTrue);
      expect(status.contactsGranted, isFalse);
    });

    test('403 surfaces needsReconnect', () async {
      final service = serviceWith({
        '/api/google/contacts': http.Response(
          jsonEncode({'error': 'insufficient scopes'}),
          403,
        ),
      });
      try {
        await service.fetchContacts(forceRefresh: true);
        fail('expected a GoogleContactsException');
      } on GoogleContactsException catch (e) {
        expect(e.needsReconnect, isTrue);
        expect(e.statusCode, 403);
      }
    });

    test('contact converts to a task assignee', () async {
      const contact = GoogleContact(
        id: 'people/1',
        displayName: 'Amy',
        email: 'amy@test.com',
      );
      final assignee = contact.toAssignee();
      expect(assignee.id, 'people/1');
      expect(assignee.displayName, 'Amy');
      expect(assignee.email, 'amy@test.com');
    });
  });
}
