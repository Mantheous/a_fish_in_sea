import 'dart:convert';

import 'package:a_fish_in_sea/planner/service/canvas_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

CanvasService serviceWith(Map<String, http.Response> routes) {
  return CanvasService(
    baseUrl: () => '',
    userId: () => 'u',
    client: MockClient((request) async {
      final path = request.url.path.replaceFirst(RegExp(r'^/fish'), '');
      return routes[path] ?? http.Response('Not found', 404);
    }),
  );
}

void main() {
  group('CanvasSubmission', () {
    test('submitted or excused counts as done, graded alone does not', () {
      expect(
        const CanvasSubmission(assignmentId: 1, submitted: true).countsAsDone,
        isTrue,
      );
      expect(
        const CanvasSubmission(assignmentId: 1, excused: true).countsAsDone,
        isTrue,
      );
      expect(
        const CanvasSubmission(assignmentId: 1, graded: true).countsAsDone,
        isFalse,
      );
      expect(
        const CanvasSubmission(assignmentId: 1).countsAsDone,
        isFalse,
      );
    });

    test('fromJson tolerates string ids and missing flags', () {
      final s = CanvasSubmission.fromJson({
        'assignment_id': '42',
        'submitted': true,
      });
      expect(s.assignmentId, 42);
      expect(s.submitted, isTrue);
      expect(s.excused, isFalse);
    });
  });

  group('CanvasService transport', () {
    test('fetchAssignment parses the detail envelope', () async {
      final service = serviceWith({
        '/api/canvas/assignment/99': http.Response(
          jsonEncode({
            'host': 'byu.instructure.com',
            'assignment_id': 99,
            'title': 'Essay 2',
            'description': '<p>Write 800 words.</p>',
            'html_url': 'https://byu.instructure.com/courses/7/assignments/99',
          }),
          200,
        ),
      });
      final detail = await service.fetchAssignment(99, courseId: 7);
      expect(detail['assignment_id'], 99);
      expect(detail['description'], '<p>Write 800 words.</p>');
      expect(detail['html_url'], contains('/assignments/99'));
    });

    test('fetchSubmissions parses the server envelope', () async {
      final service = serviceWith({
        '/api/canvas/submissions': http.Response(
          jsonEncode({
            'host': 'byu.instructure.com',
            'submissions': [
              {'assignment_id': 42, 'submitted': true},
              {'assignment_id': 43, 'graded': true},
            ],
          }),
          200,
        ),
      });
      final submissions = await service.fetchSubmissions();
      expect(submissions, hasLength(2));
      expect(submissions.first.assignmentId, 42);
      expect(submissions.first.countsAsDone, isTrue);
      expect(submissions.last.countsAsDone, isFalse);
    });

    test('status and connect round-trip', () async {
      final service = serviceWith({
        '/api/canvas/status': http.Response(
          jsonEncode({'connected': true, 'host': 'byu.instructure.com'}),
          200,
        ),
        '/api/canvas/connect': http.Response(
          jsonEncode({'status': 'connected'}),
          200,
        ),
      });
      expect(await service.isConnected(), isTrue);
      expect(await service.connectedHost(), 'byu.instructure.com');
      await service.connect(token: 't', host: 'byu.instructure.com');
    });

    test('401 with needsReconnect surfaces a reconnectable error', () async {
      final service = serviceWith({
        '/api/canvas/submissions': http.Response(
          jsonEncode({
            'detail': {
              'error': 'Canvas account not connected',
              'needsReconnect': true,
            },
          }),
          401,
        ),
      });
      try {
        await service.fetchSubmissions();
        fail('expected CanvasException');
      } on CanvasException catch (e) {
        expect(e.needsReconnect, isTrue);
        expect(e.statusCode, 401);
      }
    });

    test('expired app session retries once with a fresh token', () async {
      var calls = 0;
      var refreshed = false;
      String? token = 'stale';
      final authHeaders = <String?>[];
      final service = CanvasService(
        baseUrl: () => '',
        userId: () => 'u',
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
              'submissions': [
                {'assignment_id': 42, 'submitted': true},
              ],
            }),
            200,
          );
        }),
      );
      final submissions = await service.fetchSubmissions();
      expect(submissions, hasLength(1));
      expect(submissions.first.assignmentId, 42);
      expect(refreshed, isTrue);
      expect(calls, 2);
      expect(authHeaders[0], 'Bearer stale');
      expect(authHeaders[1], 'Bearer fresh');
    });

    test('does not refresh for Canvas-side auth failures', () async {
      var refreshed = false;
      var calls = 0;
      final service = CanvasService(
        baseUrl: () => '',
        userId: () => 'u',
        authToken: () => 'stale',
        refreshAccessToken: () async {
          refreshed = true;
          return 'fresh';
        },
        client: MockClient((request) async {
          calls++;
          return http.Response(
            jsonEncode({
              'detail': {
                'error': 'Canvas account not connected',
                'needsReconnect': true,
              },
            }),
            401,
          );
        }),
      );
      try {
        await service.fetchSubmissions();
        fail('expected CanvasException');
      } on CanvasException catch (e) {
        expect(e.needsReconnect, isTrue);
      }
      expect(refreshed, isFalse);
      expect(calls, 1);
    });
  });
}
