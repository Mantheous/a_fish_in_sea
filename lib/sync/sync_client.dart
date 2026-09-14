import 'dart:convert';
import 'dart:math' show min;

import 'package:http/http.dart' as http;

import '../planner/service/server_base.dart';

/// Typed error for sync transport failures.
class SyncException implements Exception {
  final int statusCode;
  final String message;
  const SyncException(this.statusCode, this.message);
  @override
  String toString() => 'SyncException($statusCode): $message';
}

/// Static bearer-token hook for services constructed inside cubits
/// (e.g. [PlaidService]) that cannot take a context-backed closure.
/// Set once in main.dart; services prefer an explicit `authToken`
/// parameter and fall back to this.
class SyncAuth {
  static String? Function()? tokenProvider;
  static String? current() => tokenProvider?.call();
}

/// Single pull record from the server envelope.
class SyncRecord {
  final String collection;
  final String itemId;
  final Map<String, dynamic> data;
  final bool deleted;
  final int rev;
  final DateTime updatedAt;

  const SyncRecord({
    required this.collection,
    required this.itemId,
    required this.data,
    required this.deleted,
    required this.rev,
    required this.updatedAt,
  });

  factory SyncRecord.fromJson(Map<String, dynamic> json) => SyncRecord(
        collection: json['collection'] as String,
        itemId: json['item_id'] as String,
        data: (json['data'] as Map?) == null
            ? const {}
            : Map<String, dynamic>.from(json['data'] as Map),
        deleted: json['deleted'] as bool? ?? false,
        rev: (json['rev'] as num?)?.toInt() ?? 0,
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );
}

/// Minimal HTTP client for the FastAPI sync backend.
///
/// Auth tokens are supplied by callbacks so this class stays a pure
/// transport; [AuthCubit] owns the tokens (see auth_cubit.dart).
class SyncClient {
  final String Function() serverBase;
  final String? Function() accessToken;
  final Future<String?> Function() refreshAccessToken;
  final http.Client _client;

  SyncClient({
    required this.serverBase,
    required this.accessToken,
    required this.refreshAccessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  String get _base =>
      resolveAppServerBase(serverBase()).replaceAll(RegExp(r'/+$'), '');

  Map<String, String> _headers({bool json = false}) {
    final h = <String, String>{};
    final token = accessToken();
    if (token != null && token.isNotEmpty) {
      h['Authorization'] = 'Bearer $token';
    }
    if (json) h['Content-Type'] = 'application/json';
    return h;
  }

  dynamic _decode(http.Response r) {
    dynamic body;
    try {
      body = r.body.isEmpty ? {} : jsonDecode(r.body);
    } catch (_) {
      body = {};
    }
    if (r.statusCode >= 400) {
      final msg = body is Map && body['detail'] != null
          ? body['detail'].toString()
          : 'HTTP ${r.statusCode}';
      throw SyncException(r.statusCode, msg);
    }
    return body;
  }

  /// POST with one automatic token refresh on 401. Returns decoded JSON.
  Future<dynamic> _postAuthed(String path, Map<String, dynamic> body) async {
    final uri = Uri.parse('$_base$path');
    var r = await _client.post(uri,
        headers: _headers(json: true), body: jsonEncode(body));
    if (r.statusCode == 401) {
      final fresh = await refreshAccessToken();
      if (fresh == null || fresh.isEmpty) {
        throw SyncException(401, 'Signed out');
      }
      r = await _client.post(uri,
          headers: _headers(json: true), body: jsonEncode(body));
    }
    return _decode(r);
  }

  Future<dynamic> _getAuthed(String path, [Map<String, String>? query]) async {
    var uri = Uri.parse('$_base$path');
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: {...uri.queryParameters, ...query});
    }
    var r = await _client.get(uri, headers: _headers());
    if (r.statusCode == 401) {
      final fresh = await refreshAccessToken();
      if (fresh == null || fresh.isEmpty) {
        throw SyncException(401, 'Signed out');
      }
      r = await _client.get(uri, headers: _headers());
    }
    return _decode(r);
  }

  // ── Auth (no bearer needed) ──────────────────────────────────────────

  Future<Map<String, dynamic>> register(String email, String password) async {
    final r = await _client.post(
      Uri.parse('$_base/api/v1/auth/register'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    return Map<String, dynamic>.from(_decode(r) as Map);
  }

  Future<Map<String, dynamic>> login(String email, String password) async {
    final r = await _client.post(
      Uri.parse('$_base/api/v1/auth/login'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    return Map<String, dynamic>.from(_decode(r) as Map);
  }

  Future<Map<String, dynamic>> refresh(String refreshToken) async {
    final r = await _client.post(
      Uri.parse('$_base/api/v1/auth/refresh'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'refresh_token': refreshToken}),
    );
    return Map<String, dynamic>.from(_decode(r) as Map);
  }

  /// Best-effort server-side logout: revokes the refresh token so it
  /// can't be rotated after sign-out. Never throws.
  Future<void> logout(String refreshToken) async {
    try {
      await _client
          .post(
            Uri.parse('$_base/api/v1/auth/logout'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh_token': refreshToken}),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  // ── Sync ─────────────────────────────────────────────────────────────

  /// Pull changes since [since] (server_time ISO string, null = everything).
  /// Follows has_more pages internally.
  Future<({List<SyncRecord> changes, String serverTime})> pull({
    String? since,
    List<String>? collections,
  }) async {
    final all = <SyncRecord>[];
    var cursor = since;
    String serverTime = '';
    for (var page = 0; page < 25; page++) {
      final query = <String, String>{'limit': '1000'};
      if (cursor != null && cursor.isNotEmpty) query['since'] = cursor;
      if (collections != null && collections.isNotEmpty) {
        query['collections'] = collections.join(',');
      }
      final body =
          Map<String, dynamic>.from(await _getAuthed('/api/v1/sync/pull', query));
      final changes = (body['changes'] as List? ?? const [])
          .map((e) => SyncRecord.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      all.addAll(changes);
      serverTime = body['server_time'] as String? ?? '';
      if (body['has_more'] != true || changes.isEmpty) break;
      cursor = changes.last.updatedAt.toIso8601String();
    }
    return (changes: all, serverTime: serverTime);
  }

  /// Pushes in 400-item chunks: a full first-sync (years of points and
  /// events) exceeds the server's per-request cap, which answers 422.
  Future<List<SyncRecord>> push(
      List<Map<String, dynamic>> changes) async {
    const chunk = 400;
    final applied = <SyncRecord>[];
    for (var i = 0; i < changes.length; i += chunk) {
      final slice = changes.sublist(i, min(i + chunk, changes.length));
      final body = Map<String, dynamic>.from(
          await _postAuthed('/api/v1/sync/push', {'changes': slice}));
      applied.addAll(
          ((body['applied'] as List? ?? const []).map((e) =>
              SyncRecord.fromJson(Map<String, dynamic>.from(e as Map)))));
    }
    return applied;
  }

  Future<Map<String, dynamic>> health() async {
    final r = await _client.get(Uri.parse('$_base/api/health'));
    return Map<String, dynamic>.from(_decode(r) as Map);
  }

  // ── Server-side feed snapshots ───────────────────────────────────────

  /// Asks the server to fetch [feedId]'s URL now and cache the ICS.
  /// Throws [SyncException] on failure; callers fall back to direct fetch.
  Future<void> refreshFeedSnapshot({String? feedId, String? url}) async {
    await _postAuthed('/api/v1/fetch/refresh', {
      'feed_id': feedId ?? '',
      'url': url ?? '',
    });
  }

  /// Returns the cached snapshot (`ics`, `fetched_at`, `status`), or null
  /// when the server has none / auth is missing. Never throws for 404/401.
  Future<Map<String, dynamic>?> fetchFeedSnapshot(String feedId) async {
    try {
      final body = await _getAuthed(
          '/api/v1/fetch/snapshot', {'feed_id': feedId});
      return Map<String, dynamic>.from(body as Map);
    } on SyncException catch (e) {
      if (e.statusCode == 404 || e.statusCode == 401) return null;
      rethrow;
    }
  }
}
