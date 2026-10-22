import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../demo/demo_data.dart';
import '../../demo/demo_mode.dart';
import 'server_base.dart';

/// One Canvas assignment's submission state, as normalized by the server
/// from the planner API (`plannable_id` matches the iCal UID suffix in
/// `event-assignment-<id>`).
class CanvasSubmission {
  final int assignmentId;
  final bool submitted;
  final bool excused;
  final bool graded;
  final bool missing;
  final bool late;

  const CanvasSubmission({
    required this.assignmentId,
    this.submitted = false,
    this.excused = false,
    this.graded = false,
    this.missing = false,
    this.late = false,
  });

  /// Conservative "done elsewhere" rule: submitted or excused. A bare
  /// `graded` without submission (e.g. a posted zero) must NOT
  /// auto-complete — the student still owes the work.
  bool get countsAsDone => submitted || excused;

  factory CanvasSubmission.fromJson(Map<String, dynamic> json) {
    final rawId = json['assignment_id'];
    final assignmentId = rawId is int
        ? rawId
        : int.tryParse(rawId?.toString() ?? '') ?? -1;
    return CanvasSubmission(
      assignmentId: assignmentId,
      submitted: json['submitted'] as bool? ?? false,
      excused: json['excused'] as bool? ?? false,
      graded: json['graded'] as bool? ?? false,
      missing: json['missing'] as bool? ?? false,
      late: json['late'] as bool? ?? false,
    );
  }
}

class CanvasException implements Exception {
  final String message;
  final int? statusCode;
  final bool needsReconnect;
  const CanvasException(
    this.message, {
    this.statusCode,
    this.needsReconnect = false,
  });

  @override
  String toString() => message;
}

/// Talks to the Python server's Canvas endpoints. The server holds the
/// personal access token (per sync-user, Fernet-encrypted) and proxies
/// the Canvas planner API, so the app only deals with submission states.
class CanvasService {
  final String Function() baseUrl;
  final String Function() userId;
  final String? Function()? authToken;

  /// Refreshes the app session (JWT) and returns the new access token.
  /// Wired to [AuthCubit.refreshAccessToken] in main.dart. Without it an
  /// access token that expires mid-session (15 min) turns every Canvas
  /// call into a 401 "Invalid token" — the sync client already retries
  /// this way, the Canvas proxy did not.
  final Future<String?> Function()? refreshAccessToken;
  final http.Client _client;

  /// Bounds every request so a blackholed socket fails fast instead of
  /// hanging the caller forever.
  final Duration timeout;

  CanvasService({
    required this.baseUrl,
    required this.userId,
    this.authToken,
    this.refreshAccessToken,
    http.Client? client,
    Duration? timeout,
  })  : _client = client ?? http.Client(),
        timeout = timeout ?? const Duration(seconds: 30);

  /// JWT bearer when signed in. The legacy user-id header below is ignored
  /// by the server (kept only so signed-out calls fail as 401, not 500).
  Map<String, String> get _headers {
    final t = authToken?.call();
    if (t != null && t.isNotEmpty) return {'Authorization': 'Bearer $t'};
    return {'X-App-User-Id': userId()};
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final effectiveBase = resolveAppServerBase(baseUrl());
    final resolved = Uri.parse(
      effectiveBase.isEmpty ? path : '$effectiveBase$path',
    );
    if (query == null) return resolved;
    return resolved.replace(queryParameters: {
      ...resolved.queryParameters,
      ...query,
    });
  }

  /// Runs [request] with a timeout and converts transport failures into
  /// a [CanvasException]. On a 401 that looks like an expired app session
  /// (the server's string `detail`, e.g. "Invalid token" — not the
  /// map-shaped Canvas-error payload that carries `needsReconnect`),
  /// refreshes the session once and retries with the new bearer, mirroring
  /// [SyncClient]. Callers pass a closure so [_headers] is re-read and the
  /// retry carries the fresh token.
  Future<http.Response> _send(Future<http.Response> Function() request) async {
    final first = await _attempt(request);
    if (first.statusCode != 401 || refreshAccessToken == null) return first;
    if (!_isAppSessionExpiry(first)) return first;
    final fresh = await refreshAccessToken!();
    if (fresh == null || fresh.isEmpty) return first;
    return _attempt(request);
  }

  /// True when a 401 looks like our own JWT expired, not a Canvas-side
  /// auth failure. Canvas failures arrive as
  /// `{"detail": {"error": ..., "needsReconnect": ...}}` (map detail) and
  /// refreshing the app session can't fix those.
  bool _isAppSessionExpiry(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map) return body['detail'] is! Map;
    } catch (_) {}
    return true;
  }

  Future<http.Response> _attempt(
      Future<http.Response> Function() request) async {
    try {
      return await request().timeout(timeout);
    } on CanvasException {
      rethrow;
    } on TimeoutException {
      throw CanvasException(
        'Sync server timed out at ${resolveAppServerBase(baseUrl())} — '
        'is the server running?',
      );
    } on SocketException catch (e) {
      throw CanvasException(
        'Cannot reach the sync server at ${resolveAppServerBase(baseUrl())} '
        '(${e.message}) — is the server running and the URL correct?',
      );
    } on http.ClientException catch (e) {
      throw CanvasException(
        'Cannot reach the sync server at ${resolveAppServerBase(baseUrl())} '
        '(${e.message}) — is the server running and the URL correct?',
      );
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.statusCode != 200) {
      String message = 'Server returned ${response.statusCode}';
      bool needsReconnect = false;
      try {
        final body = jsonDecode(response.body);
        // FastAPI wraps error payloads as {"detail": {...}}; accept bare
        // maps too.
        final Map? err = body is Map && body['detail'] is Map
            ? body['detail'] as Map
            : body is Map
                ? body
                : null;
        if (err != null && err['error'] is String) {
          message = err['error'] as String;
        } else if (body is Map && body['detail'] is String) {
          message = body['detail'] as String;
        }
        if (err != null && err['needsReconnect'] == true) {
          needsReconnect = true;
        }
      } catch (_) {}
      throw CanvasException(
        message,
        statusCode: response.statusCode,
        needsReconnect: needsReconnect,
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<bool> isConnected() async {
    if (DemoMode.isActive) return DemoMocks.canvasConnected;
    final data = _decode(await _send(() => _client.get(
        _uri('/api/canvas/status'),
        headers: _headers)));
    return data['connected'] as bool? ?? false;
  }

  Future<String?> connectedHost() async {
    if (DemoMode.isActive) {
      return DemoMocks.canvasConnected ? DemoMocks.canvasHost : null;
    }
    final data = _decode(await _send(() => _client.get(
        _uri('/api/canvas/status'),
        headers: _headers)));
    return data['host'] as String?;
  }

  /// Sends the pasted personal access token to the server, which verifies
  /// it against [host] before storing. The token itself is never kept on
  /// this device beyond this call.
  Future<void> connect({required String token, required String host}) async {
    if (DemoMode.isActive) {
      // Mock token exchange: any pasted token "works".
      await Future<void>.delayed(const Duration(milliseconds: 500));
      DemoMocks.canvasConnected = true;
      DemoMocks.canvasHost =
          host.trim().isNotEmpty ? host.trim() : 'demo.instructure.com';
      return;
    }
    final response = await _send(() => _client.post(
          _uri('/api/canvas/connect'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'token': token, 'host': host}),
        ));
    _decode(response);
  }

  Future<void> disconnect() async {
    if (DemoMode.isActive) {
      DemoMocks.canvasConnected = false;
      return;
    }
    await _send(() => _client.post(
        _uri('/api/canvas/disconnect'),
        headers: _headers));
  }

  /// One assignment's details (description, link) via the server proxy.
  /// The assignment id is the iCal UID suffix (`event-assignment-<id>`);
  /// [courseId] is optional — without it the server walks the student's
  /// courses. Returns the raw detail map (`description`, `html_url`, …).
  Future<Map<String, dynamic>> fetchAssignment(
    int assignmentId, {
    int? courseId,
  }) async {
    final query = <String, String>{};
    if (courseId != null) query['course_id'] = courseId.toString();
    final data = _decode(await _send(() => _client.get(
          _uri('/api/canvas/assignment/$assignmentId',
              query.isEmpty ? null : query),
          headers: _headers)));
    return data;
  }

  /// Submission states across the server's sync window (wide enough to
  /// cover the overdue pile, not just this week).
  Future<List<CanvasSubmission>> fetchSubmissions() async {
    if (DemoMode.isActive) return DemoData.canvasSubmissions();
    final data = _decode(await _send(() => _client.get(
        _uri('/api/canvas/submissions'),
        headers: _headers)));
    final list = data['submissions'];
    if (list is! List) return const [];
    final out = <CanvasSubmission>[];
    for (final raw in list) {
      if (raw is! Map<String, dynamic>) continue;
      final submission = CanvasSubmission.fromJson(raw);
      if (submission.assignmentId >= 0) out.add(submission);
    }
    return out;
  }
}
