import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Failure talking to AnkiConnect. Messages are written for direct
/// display: they say what to do (start Anki, install the add-on, fix the
/// host) instead of leaking transport detail.
class AnkiException implements Exception {
  final String message;
  const AnkiException(this.message);

  @override
  String toString() => 'AnkiException: $message';
}

/// Minimal AnkiConnect client — only what memorization goals need.
///
/// AnkiConnect (https://foosoft.net/projects/anki-connect/) is a local
/// add-on that exposes Anki over HTTP, usually at
/// `http://127.0.0.1:8765`. The app never stores Anki credentials:
/// AnkiConnect has none, and the host URL lives in per-device settings.
///
/// Platform note: browsers cannot reach a user's AnkiConnect (mixed
/// content + no CORS headers), so the web build never calls this — it
/// offers manual entry and stats import instead. Native builds (desktop
/// first, mobile on the same network as a desktop Anki) sync directly.
///
/// Pass an [http.Client] (e.g. a `MockClient`) in tests; otherwise a
/// real client is created per instance — call [close] when done.
class AnkiConnectClient {
  static const int apiVersion = 6;

  final Uri endpoint;
  final http.Client _http;
  final Duration timeout;

  AnkiConnectClient({
    required String host,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 8),
  })  : endpoint = normalizeHost(host),
        _http = httpClient ?? http.Client();

  /// Parses [host] into an endpoint URI. Bare `host:port` gains `http://`;
  /// blank input means the AnkiConnect default. Throws [AnkiException]
  /// (displayable) on garbage.
  static Uri normalizeHost(String host) {
    var h = host.trim();
    if (h.isEmpty) h = 'http://127.0.0.1:8765';
    if (!h.contains('://')) h = 'http://$h';
    final uri = Uri.tryParse(h);
    if (uri == null || uri.host.isEmpty) {
      throw AnkiException('“$host” is not a valid Anki address.');
    }
    return uri;
  }

  void close() => _http.close();

  /// Raw AnkiConnect invoke. Returns the `result` field; any `error`
  /// field, transport failure, or timeout becomes [AnkiException].
  Future<dynamic> invoke(
    String action, [
    Map<String, dynamic> params = const {},
  ]) async {
    late http.Response res;
    try {
      res = await _http
          .post(
            endpoint,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(
                {'action': action, 'version': apiVersion, 'params': params}),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw AnkiException(
          'Anki did not answer at $endpoint — is Anki running with the '
          'AnkiConnect add-on installed?');
    } on http.ClientException catch (e) {
      throw AnkiException('Cannot reach Anki at $endpoint: ${e.message}');
    } catch (e) {
      if (e is AnkiException) rethrow;
      throw AnkiException('Cannot reach Anki at $endpoint ($e).');
    }
    if (res.statusCode != 200) {
      throw AnkiException(
          'Anki answered HTTP ${res.statusCode} — is $endpoint really AnkiConnect?');
    }
    dynamic body;
    try {
      body = jsonDecode(res.body);
    } catch (_) {
      throw AnkiException(
          'Anki answered with something that is not JSON — is $endpoint really AnkiConnect?');
    }
    if (body is! Map) {
      throw AnkiException('Anki answered in an unknown shape.');
    }
    final error = body['error'];
    if (error != null) {
      throw AnkiException('Anki says: $error');
    }
    return body['result'];
  }

  /// Deck names on the connected Anki. Doubles as a connection test.
  Future<List<String>> deckNames() async {
    final result = await invoke('deckNames');
    if (result is! List) {
      throw AnkiException('Anki answered deckNames in an unknown shape.');
    }
    return [for (final d in result) if (d is String) d];
  }

  /// Builds the `findCards` query for cards answered in the last day,
  /// optionally scoped to [deck]. Shared with the server proxy path so
  /// deck-scoped and total counts mean the same thing everywhere.
  static String scopedQuery(String? deck) {
    final d = deck?.trim() ?? '';
    final scope = d.isEmpty ? '' : 'deck:"${d.replaceAll('"', '\\"')}" ';
    return '${scope}rated:1';
  }

  /// Distinct cards answered in the last day, optionally scoped to
  /// [deck]. Uses one `findCards` query either way so deck-scoped and
  /// total counts mean the same thing.
  ///
  /// This counts cards, not reviews: a card answered twice still counts
  /// once. Good enough for "review N cards" goals, and stated on the
  /// goal so nobody mistakes it for Anki's own review total.
  Future<int> reviewsToday({String? deck}) async {
    final result = await invoke('findCards', {
      'query': scopedQuery(deck),
    });
    if (result is! List) {
      throw AnkiException('Anki answered findCards in an unknown shape.');
    }
    return result.length;
  }
}
