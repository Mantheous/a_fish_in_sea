import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../demo/demo_data.dart';
import '../demo/demo_mode.dart';
import '../planner/service/server_base.dart';
import 'fitness_models.dart';

/// Server-side connection summary for the fitness connector.
class FitnessStatus {
  final bool connected;
  final bool configured;
  final bool supportsSleep;
  final String? athlete;

  /// Callback URL to register on the Strava API app. The server derives
  /// it from the public host, so the app never has to guess.
  final String? redirectUri;

  const FitnessStatus({
    required this.connected,
    required this.configured,
    this.supportsSleep = false,
    this.athlete,
    this.redirectUri,
  });

  factory FitnessStatus.fromJson(Map<String, dynamic> json) => FitnessStatus(
        connected: json['connected'] == true,
        configured: json['configured'] == true,
        supportsSleep: json['supportsSleep'] == true,
        athlete: (json['athlete'] as String?)?.trim().isEmpty == true
            ? null
            : json['athlete'] as String?,
        redirectUri: json['redirectUri'] as String?,
      );
}

/// Typed error for the fitness proxy. [needsReconnect] means the stored
/// Strava grant is dead (revoked/expired) and only a new sign-in fixes it;
/// [needsSetup] means the server has no Strava API app configured at all.
class FitnessException implements Exception {
  final String message;
  final int? statusCode;
  final bool needsReconnect;
  final bool needsSetup;
  final String? redirectUri;

  const FitnessException(
    this.message, {
    this.statusCode,
    this.needsReconnect = false,
    this.needsSetup = false,
    this.redirectUri,
  });

  @override
  String toString() => message;
}

/// Talks to the server's `/api/fitness/*` Strava proxy. The server holds
/// the OAuth tokens; this client only reads status and normalized
/// activities, so no Strava secret ever reaches the device.
class FitnessService {
  final String Function() baseUrl;
  final String? Function() authToken;

  /// Refreshes the app session (JWT) and returns the new access token.
  final Future<String?> Function()? refreshAccessToken;
  final http.Client _client;

  FitnessService({
    required this.baseUrl,
    required this.authToken,
    this.refreshAccessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = resolveAppServerBase(baseUrl());
    final resolved = Uri.parse(base.isEmpty ? path : '$base$path');
    if (query == null || query.isEmpty) return resolved;
    return resolved.replace(queryParameters: {
      ...resolved.queryParameters,
      ...query,
    });
  }

  Map<String, String> get _headers {
    final token = authToken();
    if (token != null && token.isNotEmpty) {
      return {'Authorization': 'Bearer $token'};
    }
    return const {};
  }

  Future<FitnessStatus> status() async {
    if (DemoMode.isActive) {
      return FitnessStatus(
        connected: DemoMocks.stravaConnected,
        configured: true,
        athlete: DemoMocks.stravaConnected ? 'Demo Athlete' : null,
      );
    }
    final data = _decode(await _send(() => _client.get(
          _uri('/api/fitness/status'),
          headers: _headers,
        )));
    return FitnessStatus.fromJson(data);
  }

  /// Strava consent URL to open in a browser tab.
  Future<String> authUrl() async {
    if (DemoMode.isActive) {
      throw const FitnessException(
        'Demo connect is one-tap — use the Connect button.',
      );
    }
    final data = _decode(await _send(() => _client.get(
          _uri('/api/fitness/auth_url'),
          headers: _headers,
        )));
    final url = data['url'];
    if (url is! String || url.isEmpty) {
      throw const FitnessException('Server did not return a Strava sign-in link');
    }
    return url;
  }

  Future<void> disconnect() async {
    if (DemoMode.isActive) {
      DemoMocks.stravaConnected = false;
      return;
    }
    await _send(() => _client.post(
          _uri('/api/fitness/disconnect'),
          headers: _headers,
        ));
  }

  /// Activities from the last [days] days, oldest first.
  Future<List<FitnessActivity>> activities({int days = 30}) async {
    if (DemoMode.isActive) return const [];
    final data = _decode(await _send(() => _client.get(
          _uri('/api/fitness/activities', {'days': '$days'}),
          headers: _headers,
        )));
    final list = data['activities'];
    if (list is! List) return const [];
    return [
      for (final raw in list)
        if (raw is Map) FitnessActivity.fromJson(Map<String, dynamic>.from(raw)),
    ];
  }

  /// Strava has no sleep API, so this is always empty — the server says
  /// so explicitly and sleep goals stay unsupported.
  Future<List<SleepSample>> sleep() async {
    if (DemoMode.isActive) return const [];
    final data = _decode(await _send(() => _client.get(
          _uri('/api/fitness/sleep'),
          headers: _headers,
        )));
    final list = data['sleep'];
    if (list is! List) return const [];
    return [
      for (final raw in list)
        if (raw is Map) SleepSample.fromJson(Map<String, dynamic>.from(raw)),
    ];
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    final first = await _attempt(request);
    if (first.statusCode != 401 || refreshAccessToken == null) return first;
    if (!_isAppSessionExpiry(first)) return first;
    final fresh = await refreshAccessToken!();
    if (fresh == null || fresh.isEmpty) return first;
    return _attempt(request);
  }

  /// Strava failures arrive as a map-shaped `detail` with `needsReconnect`
  /// or `needsSetup`; a plain string `detail` is our own JWT expiring.
  bool _isAppSessionExpiry(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map) return body['detail'] is! Map;
    } catch (_) {}
    return true;
  }

  Future<http.Response> _attempt(
    Future<http.Response> Function() request,
  ) async {
    try {
      return await request().timeout(const Duration(seconds: 30));
    } on FitnessException {
      rethrow;
    } on TimeoutException {
      throw FitnessException(
        'Sync server timed out at ${resolveAppServerBase(baseUrl())} — '
        'is the server running?',
      );
    } on SocketException catch (e) {
      throw FitnessException(
        'Cannot reach the sync server at ${resolveAppServerBase(baseUrl())} '
        '(${e.message}) — is the server running and the URL correct?',
      );
    } on http.ClientException catch (e) {
      throw FitnessException(
        'Cannot reach the sync server at ${resolveAppServerBase(baseUrl())} '
        '(${e.message}) — is the server running and the URL correct?',
      );
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var message = 'Server returned ${response.statusCode}';
      var needsReconnect = false;
      var needsSetup = false;
      String? redirectUri;
      try {
        final body = jsonDecode(response.body);
        final Map? err = body is Map && body['detail'] is Map
            ? body['detail'] as Map
            : body is Map
                ? body
                : null;
        if (err != null) {
          if (err['error'] is String) message = err['error'] as String;
          if (err['detail'] is String && err['error'] == null) {
            message = err['detail'] as String;
          }
          needsReconnect = err['needsReconnect'] == true;
          needsSetup = err['needsSetup'] == true;
          if (err['redirectUri'] is String) {
            redirectUri = err['redirectUri'] as String;
          }
        } else if (body is Map && body['detail'] is String) {
          message = body['detail'] as String;
        }
      } catch (_) {
        // Non-JSON bodies (proxy HTML) keep the status-code message.
      }
      throw FitnessException(
        message,
        statusCode: response.statusCode,
        needsReconnect: needsReconnect,
        needsSetup: needsSetup,
        redirectUri: redirectUri,
      );
    }
    final decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FitnessException('Server returned an unexpected response');
    }
    return Map<String, dynamic>.from(decoded);
  }

  void close() => _client.close();

  /// Only for tests: lets a fake client be swapped in without HTTP.
  @visibleForTesting
  http.Client get httpClient => _client;
}
