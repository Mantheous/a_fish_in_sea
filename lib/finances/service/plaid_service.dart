import 'dart:convert';
import 'package:http/http.dart' as http;

/// HTTP client that communicates with the local Plaid quickstart server.
///
/// The server runs at [baseUrl] (default `http://127.0.0.1:8000`) and
/// proxies calls to the Plaid API using server-side credentials.
/// Each app install sends [userId] so multiple dev users can connect
/// different sandbox banks without overwriting each other.
class PlaidService {
  final String baseUrl;
  final String userId;
  final http.Client _client;

  PlaidService({
    this.baseUrl = 'http://127.0.0.1:8000',
    required this.userId,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Map<String, String> get _headers => {'X-Plaid-User-Id': userId};

  // ── Link flow ───────────────────────────────────────────────────────

  /// Request a Link token from the server for initialising Plaid Link.
  Future<String> createLinkToken() async {
    final response = await _client.post(
      Uri.parse('$baseUrl/api/create_link_token'),
      headers: _headers,
    );
    _checkResponse(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['link_token'] as String;
  }

  /// Exchange a public token (from Plaid Link) for an access token.
  /// The access token is stored server-side per [userId].
  Future<Map<String, dynamic>> exchangePublicToken(String publicToken) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/api/set_access_token'),
      headers: _headers,
      body: {'public_token': publicToken},
    );
    _checkResponse(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Remove the stored bank connection for this user.
  Future<void> disconnect() async {
    final response = await _client.post(
      Uri.parse('$baseUrl/api/disconnect'),
      headers: _headers,
    );
    _checkResponse(response);
  }

  // ── Sandbox auto-connect ────────────────────────────────────────────

  /// Automatically connect a sandbox institution without going through
  /// the Plaid Link UI. Only works in sandbox environment.
  Future<void> sandboxAutoConnect() async {
    final response = await _client.post(
      Uri.parse('$baseUrl/api/sandbox/auto_connect'),
      headers: _headers,
    );
    _checkResponse(response);
  }

  // ── Data retrieval ──────────────────────────────────────────────────

  /// Fetch all transactions via the Transactions Sync endpoint.
  Future<List<Map<String, dynamic>>> getTransactions() async {
    final response = await _client.get(
      Uri.parse('$baseUrl/api/transactions'),
      headers: _headers,
    );
    _checkResponse(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final transactions = body['latest_transactions'] as List<dynamic>;
    return transactions.cast<Map<String, dynamic>>();
  }

  /// Fetch account balances.
  Future<Map<String, dynamic>> getBalance() async {
    final response = await _client.get(
      Uri.parse('$baseUrl/api/balance'),
      headers: _headers,
    );
    _checkResponse(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Fetch account information.
  Future<List<Map<String, dynamic>>> getAccounts() async {
    final response = await _client.get(
      Uri.parse('$baseUrl/api/accounts'),
      headers: _headers,
    );
    _checkResponse(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final accounts = body['accounts'] as List<dynamic>;
    return accounts.cast<Map<String, dynamic>>();
  }

  /// Check server info (access token status, products, etc.).
  Future<Map<String, dynamic>> getInfo() async {
    final response = await _client.post(
      Uri.parse('$baseUrl/api/info'),
      headers: _headers,
    );
    _checkResponse(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  void _checkResponse(http.Response response) {
    if (response.statusCode >= 400) {
      String message;
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
        message =
            'Plaid server error (${response.statusCode}): ${response.body}';
      }
      throw PlaidServiceException(message, response.statusCode);
    }
  }

  void dispose() {
    _client.close();
  }
}

/// Exception thrown when the Plaid server returns an error.
class PlaidServiceException implements Exception {
  final String message;
  final int statusCode;

  const PlaidServiceException(this.message, this.statusCode);

  @override
  String toString() => 'PlaidServiceException($statusCode): $message';
}
