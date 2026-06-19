import 'dart:convert';

import 'package:a_fish_in_sea/finances/service/plaid_config.dart';
import 'package:http/http.dart' as http;

import 'plaid_service_io.dart'
    if (dart.library.html) 'plaid_service_stub.dart' as platform_url;

/// HTTP client for the local Plaid backend ([PlaidConfig.serverUrl]).
class PlaidService {
  final String baseUrl;
  final String userId;
  final http.Client _client;

  PlaidService({
    String? baseUrl,
    required this.userId,
    http.Client? client,
  })  : baseUrl = baseUrl ?? _defaultBaseUrl(),
        _client = client ?? http.Client();

  static String _defaultBaseUrl() => platform_url.resolvePlaidBaseUrl();

  Map<String, String> get _headers => {'X-Plaid-User-Id': userId};

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
        '  cd server/python && ./start.sh',
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
