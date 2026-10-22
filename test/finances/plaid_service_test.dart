import 'dart:convert';

import 'package:a_fish_in_sea/finances/service/plaid_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('PlaidService transport', () {
    test('hung request fails fast via timeout', () async {
      final service = PlaidService(
        userId: 'u',
        baseUrl: 'http://localhost:8000',
        timeout: const Duration(milliseconds: 100),
        client: MockClient((request) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return http.Response('{}', 200);
        }),
      );
      try {
        await service.getAccounts();
        fail('expected PlaidServiceException');
      } on PlaidServiceException catch (e) {
        expect(e.isUnreachable, isTrue);
      }
    });

    test('expired app session retries once with a fresh token', () async {
      var calls = 0;
      var refreshed = false;
      String? token = 'stale';
      final authHeaders = <String?>[];
      final service = PlaidService(
        userId: 'u',
        baseUrl: 'http://localhost:8000',
        authToken: () => token,
        refreshAccessToken: () async {
          refreshed = true;
          token = 'fresh';
          return token;
        },
        client: MockClient((request) async {
          calls++;
          authHeaders.add(request.headers['Authorization']);
          if (calls == 1) {
            return http.Response(
              jsonEncode({'detail': 'Invalid token'}),
              401,
            );
          }
          return http.Response(
            jsonEncode({
              'accounts': [
                {'account_id': 'a1'},
              ],
            }),
            200,
          );
        }),
      );
      final accounts = await service.getAccounts();
      expect(accounts, hasLength(1));
      expect(refreshed, isTrue);
      expect(calls, 2);
      expect(authHeaders[0], 'Bearer stale');
      expect(authHeaders[1], 'Bearer fresh');
    });

    test('bank-not-connected 401 does not trigger a refresh', () async {
      var refreshed = false;
      var calls = 0;
      final service = PlaidService(
        userId: 'u',
        baseUrl: 'http://localhost:8000',
        authToken: () => 'stale',
        refreshAccessToken: () async {
          refreshed = true;
          return 'fresh';
        },
        client: MockClient((request) async {
          calls++;
          return http.Response(
            jsonEncode({
              'error': {'message': 'No bank account connected'},
            }),
            401,
          );
        }),
      );
      try {
        await service.getAccounts();
        fail('expected PlaidServiceException');
      } on PlaidServiceException catch (e) {
        expect(e.message, contains('No bank account connected'));
      }
      expect(refreshed, isFalse);
      expect(calls, 1);
    });
  });
}
