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
  });
}
