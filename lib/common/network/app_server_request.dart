import 'dart:convert';

import 'package:http/http.dart' as http;

/// App JWT failures use a string `detail`; provider failures carry an error
/// envelope. Refreshing an app session cannot repair a provider connection.
bool isAppSessionExpiry(http.Response response) {
  if (response.statusCode != 401) return false;
  try {
    final body = jsonDecode(response.body);
    if (body is Map) {
      return body['detail'] is! Map && !body.containsKey('error');
    }
  } catch (_) {}
  return true;
}

/// Bounds every attempt, including reading its body, and retries only an
/// explicitly rejected app session once. Timeouts are never retried: a write
/// may already have reached the server even when its response was lost.
Future<http.Response> sendAppServerRequest(
  Future<http.Response> Function() request, {
  Future<String?> Function()? refreshAccessToken,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final first = await request().timeout(timeout);
  if (refreshAccessToken == null || !isAppSessionExpiry(first)) return first;
  final fresh = await refreshAccessToken().timeout(timeout);
  if (fresh == null || fresh.isEmpty) return first;
  // The closure must re-read the bearer token for this attempt.
  return request().timeout(timeout);
}
