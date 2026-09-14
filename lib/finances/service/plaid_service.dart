import 'dart:convert';

import 'package:a_fish_in_sea/sync/sync_client.dart' show SyncAuth;
import 'package:http/http.dart' as http;

import 'plaid_service_io.dart'
    if (dart.library.html) 'plaid_service_stub.dart' as platform_url;

/// HTTP client for the Plaid backend (the one app server).
class PlaidService {
  final String baseUrl;
  final String userId;
  final String? Function()? authToken;
  final http.Client _client;

  PlaidService({
    String? baseUrl,
    required this.userId,
    this.authToken,
    http.Client? client,
  })  : baseUrl = baseUrl ?? _defaultBaseUrl(),
        _client = client ?? http.Client();

  static String _defaultBaseUrl() => platform_url.resolvePlaidBaseUrl();

  /// JWT bearer when signed in. The legacy user-id header below is ignored
  /// by the server (kept only so signed-out calls fail as 401, not 500).
  /// Defaults to the global [SyncAuth] hook because [PlaidCubit] builds this
  /// service internally (no context for a closure).
  Map<String, String> get _headers {
    final provider = authToken ?? SyncAuth.current;
    final t = provider();
    if (t != null && t.isNotEmpty) return {'Authorization': 'Bearer $t'};
    return {'X-Plaid-User-Id': userId};
  }

  Future<String> createLinkToken() async {
    final response = await _post('/api/create_link_token');
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['link_token'] as String;
  }

  Future<Map<String, dynamic>> exchangePublicToken(String publicToken) async {
    final response = await _post(
      '/api/set_access_token',
      body: {'public_token': publicToken},
    );
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> disconnect() async {
    await _post('/api/disconnect');
  }

  Future<void> sandboxAutoConnect() async {
    await _post('/api/sandbox/auto_connect');
  }

  Future<List<Map<String, dynamic>>> getTransactions() async {
    final response = await _get('/api/transactions');
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final transactions = body['latest_transactions'] as List<dynamic>;
    return transactions.cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> getBalance() async {
    final response = await _get('/api/balance');
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> getAccounts() async {
    final response = await _get('/api/accounts');
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final accounts = body['accounts'] as List<dynamic>;
    return accounts.cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> getInfo() async {
    final response = await _post('/api/info');
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Best-effort Link exit telemetry (`/api/link_exit_error` is open, no
  /// JWT needed). Never throws — diagnostics must not break the flow.
  Future<void> logLinkExitError(Map<String, dynamic> payload) async {
    try {
      await _client
          .post(
            Uri.parse('$baseUrl/api/link_exit_error'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// True when the backend responds to a health check.
  Future<bool> isServerReachable() async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/api/health'))
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<http.Response> _get(String path) async {
    try {
      final response =
          await _client.get(Uri.parse('$baseUrl$path'), headers: _headers);
      _checkResponse(response);
      return response;
    } catch (e) {
      throw _mapRequestError(e);
    }
  }

  Future<http.Response> _post(
    String path, {
    Map<String, String>? body,
  }) async {
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl$path'),
        headers: _headers,
        body: body,
      );
      _checkResponse(response);
      return response;
    } catch (e) {
      throw _mapRequestError(e);
    }
  }

  PlaidServiceException _mapRequestError(Object e) {
    if (e is PlaidServiceException) return e;
    if (platform_url.isConnectionError(e)) {
      return PlaidServiceException(
        'Cannot reach the Plaid server at $baseUrl. '
        'Start it from the project root:\n'
        '  cd server/api && .venv/bin/uvicorn app.main:app --port 8000',
        0,
      );
    }
    if (e is FormatException) {
      return PlaidServiceException(
        'Plaid server returned an invalid response. '
        'Is the correct server running on $baseUrl?',
        0,
      );
    }
    return PlaidServiceException(e.toString(), 0);
  }

  void _checkResponse(http.Response response) {
    if (response.statusCode >= 400) {
      String message;
      final contentType = response.headers['content-type'] ?? '';
      final isHtml = contentType.contains('text/html') ||
          response.body.trimLeft().startsWith('<!');

      if (isHtml) {
        message = response.statusCode == 500
            ? 'Plaid server error (500). Check the server terminal for details.'
            : 'Unexpected HTML response (${response.statusCode}) from $baseUrl. '
                'Another app may be using that port, or the Plaid server is not running.';
      } else {
        try {
          final body = jsonDecode(response.body) as Map<String, dynamic>;
          final error = body['error'];
          if (error is Map<String, dynamic>) {
            message = error['message'] as String? ??
                error['error_message'] as String? ??
                'Plaid API error (${response.statusCode})';
          } else if (error is String) {
            message = error;
          } else {
            message = 'Plaid API error (${response.statusCode})';
          }
        } catch (_) {
          message = 'Plaid server error (${response.statusCode})';
        }
      }
      throw PlaidServiceException(message, response.statusCode);
    }
  }

  void dispose() {
    _client.close();
  }
}

class PlaidServiceException implements Exception {
  final String message;
  final int statusCode;

  const PlaidServiceException(this.message, this.statusCode);

  bool get isUnreachable => statusCode == 0;

  @override
  String toString() => 'PlaidServiceException($statusCode): $message';
}
