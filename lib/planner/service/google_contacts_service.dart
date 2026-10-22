import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../model/task_assignee.dart';
import '../../demo/demo_data.dart';
import '../../demo/demo_mode.dart';
import 'server_base.dart';

class GoogleContact {
  final String id;
  final String displayName;
  final String? email;
  final String? photoUrl;

  const GoogleContact({
    required this.id,
    required this.displayName,
    this.email,
    this.photoUrl,
  });

  String get searchKey =>
      '${displayName.toLowerCase()} ${(email ?? '').toLowerCase()}';

  bool matchesQuery(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return searchKey.contains(q);
  }

  TaskAssignee toAssignee() => TaskAssignee(
        id: id,
        displayName: displayName,
        email: email,
        photoUrl: photoUrl,
      );

  factory GoogleContact.fromJson(Map<String, dynamic> json) {
    final rawId = (json['id'] as String?)?.trim() ?? '';
    final rawName = (json['displayName'] as String?)?.trim() ?? '';
    final rawEmail = (json['email'] as String?)?.trim();
    final rawPhoto = (json['photoUrl'] as String?)?.trim();
    final id = rawId.isNotEmpty
        ? rawId
        : (rawEmail ?? '').isNotEmpty
            ? rawEmail!
            : rawName;
    final displayName =
        rawName.isNotEmpty ? rawName : (rawEmail ?? '').isNotEmpty ? rawEmail! : id;
    if (id.isEmpty || displayName.isEmpty) {
      throw const FormatException('Contact needs an id or name');
    }
    return GoogleContact(
      id: id,
      displayName: displayName,
      email: (rawEmail ?? '').isEmpty ? null : rawEmail,
      photoUrl: (rawPhoto ?? '').isEmpty ? null : rawPhoto,
    );
  }
}

class GoogleContactsException implements Exception {
  final String message;
  final int? statusCode;
  final bool needsReconnect;
  const GoogleContactsException(
    this.message, {
    this.statusCode,
    this.needsReconnect = false,
  });

  @override
  String toString() => message;
}

class GoogleContactsStatus {
  final bool connected;
  final bool contactsGranted;
  const GoogleContactsStatus({
    required this.connected,
    required this.contactsGranted,
  });
}

/// Talks to the Python server's People proxy. The server holds the OAuth
/// tokens, so the app only deals with a cached flat contact list that the
/// task editor filters locally.
class GoogleContactsService {
  final String Function() baseUrl;
  final String Function() userId;
  final String? Function()? authToken;

  /// Refreshes the app session (JWT) and returns the new access token.
  /// Wired to [AuthCubit.refreshAccessToken] where the service is built.
  /// Without it an access token that expires mid-session (15 min) turns
  /// every contacts call into a 401 "Invalid token" until something else
  /// happens to refresh the token.
  final Future<String?> Function()? refreshAccessToken;
  final http.Client _client;

  /// Bounds every request so a blackholed socket fails fast instead of
  /// hanging the caller forever.
  final Duration timeout;
  List<GoogleContact>? _cache;

  /// Shared across editor instances: every event/task editor builds its own
  /// service, so a per-instance cache never hits and each editor open cost
  /// two HTTP round trips (status + contacts), making the editor feel slow.
  static List<GoogleContact>? _sharedCache;
  static Future<List<GoogleContact>>? _sharedFetch;

  GoogleContactsService({
    required this.baseUrl,
    required this.userId,
    this.authToken,
    this.refreshAccessToken,
    http.Client? client,
    Duration? timeout,
  })  : _client = client ?? http.Client(),
        timeout = timeout ?? const Duration(seconds: 30);

  /// JWT bearer when signed in (FastAPI); legacy user-id header otherwise.
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
  /// a [GoogleContactsException]. On a 401 that looks like an expired app
  /// session (the server's string `detail`, e.g. "Invalid token" — not the
  /// map-shaped Google-error payload that carries `needsReconnect`),
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

  /// True when a 401 looks like our own JWT expired, not a Google-side
  /// auth failure. Google failures arrive as
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
    } on GoogleContactsException {
      rethrow;
    } on TimeoutException {
      throw GoogleContactsException(
        'Sync server timed out at ${resolveAppServerBase(baseUrl())} — '
        'is the server running?',
      );
    } on SocketException catch (e) {
      throw GoogleContactsException(
        'Cannot reach the sync server at ${resolveAppServerBase(baseUrl())} '
        '(${e.message}) — is the server running and the URL correct?',
      );
    } on http.ClientException catch (e) {
      throw GoogleContactsException(
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
        // FastAPI wraps error payloads as {"detail": {...}} while the
        // legacy Flask server returned them bare; accept both.
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
      if (response.statusCode == 403) {
        // App-session JWT failures never answer 403 (they are 401 with a
        // string detail, already retried via refresh above), so a 403 is
        // always provider-side: scopes revoked or consent withdrawn.
        needsReconnect = true;
      } else if (response.statusCode == 401) {
        // Only provider-side (map-detail) 401s mean the Google grant
        // broke. A string-detail 401 is the expired app JWT — it was
        // already retried via refresh and must not prompt a false
        // "reconnect Google" when the refresh yields nothing.
        var appJwt = false;
        try {
          final body = jsonDecode(response.body);
          if (body is Map) appJwt = body['detail'] is String;
        } catch (_) {}
        if (!appJwt) needsReconnect = true;
      }
      throw GoogleContactsException(
        message,
        statusCode: response.statusCode,
        needsReconnect: needsReconnect,
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<GoogleContactsStatus> status() async {
    if (DemoMode.isActive) {
      return GoogleContactsStatus(
        connected: DemoMocks.googleConnected,
        contactsGranted: DemoMocks.googleConnected,
      );
    }
    final data = _decode(await _send(() => _client.get(
        _uri('/api/google/status'),
        headers: _headers)));
    return GoogleContactsStatus(
      connected: data['connected'] as bool? ?? false,
      contactsGranted: data['contactsGranted'] as bool? ?? false,
    );
  }

  Future<List<GoogleContact>> fetchContacts({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final hit = _cache ?? _sharedCache;
      if (hit != null) {
        _cache = hit;
        return hit;
      }
      final inflight = _sharedFetch;
      if (inflight != null) {
        final shared = await inflight;
        _cache = shared;
        return shared;
      }
    }
    final future = _fetchAndCache();
    if (!forceRefresh) _sharedFetch = future;
    try {
      return await future;
    } finally {
      if (!forceRefresh && identical(_sharedFetch, future)) {
        _sharedFetch = null;
      }
    }
  }

  Future<List<GoogleContact>> _fetchAndCache() async {
    if (DemoMode.isActive) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final out = [...DemoData.googleContacts()]..sort((a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
      _cache = out;
      _sharedCache = out;
      return out;
    }
    final data = _decode(await _send(() => _client.get(
        _uri('/api/google/contacts'),
        headers: _headers)));
    final list = data['contacts'];
    final out = <GoogleContact>[];
    if (list is List) {
      for (final raw in list) {
        if (raw is! Map) continue;
        try {
          out.add(GoogleContact.fromJson(Map<String, dynamic>.from(raw)));
        } catch (_) {}
      }
    }
    out.sort((a, b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    _cache = out;
    _sharedCache = out;
    return out;
  }

  List<GoogleContact> searchCached(String query, {int limit = 20}) {
    final cache = _cache ?? _sharedCache;
    if (cache == null) return const [];
    final q = query.trim().toLowerCase();
    final matches = q.isEmpty
        ? cache.take(limit).toList()
        : cache.where((c) => c.matchesQuery(q)).take(limit).toList();
    return matches;
  }

  void clearCache() {
    _cache = null;
    _sharedCache = null;
  }

  static void clearSharedCache() => _sharedCache = null;
}
