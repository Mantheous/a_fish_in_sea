import 'package:a_fish_in_sea/anki/anki_connect.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';

/// Failure talking to Anki through the app server. Messages are written
/// for direct display, matching [AnkiException].
class AnkiServerException implements Exception {
  final String message;
  const AnkiServerException(this.message);

  @override
  String toString() => 'AnkiServerException: $message';
}

/// Same AnkiConnect reads as [AnkiConnectClient], routed through the app
/// server's `POST /api/anki/invoke` so web builds (which cannot reach
/// AnkiConnect directly) can sync too. Requires a signed-in [client];
/// a 401 becomes a sign-in prompt instead of a transport dump.
Future<dynamic> _invoke(
  SyncClient client,
  String action, [
  Map<String, dynamic> params = const {},
]) async {
  dynamic body;
  try {
    body = await client.ankiInvoke(action, params);
  } on SyncException catch (e) {
    if (e.statusCode == 401) {
      throw const AnkiServerException(
          'Sign in to sync Anki counts through the server.');
    }
    throw AnkiServerException(e.message.isEmpty
        ? 'Server returned ${e.statusCode} — is Anki running on the server?'
        : e.message);
  }
  if (body is Map && body.containsKey('result')) return body['result'];
  throw const AnkiServerException('Server answered in an unknown shape.');
}

/// Deck names on the server-side Anki. Doubles as a connection test.
Future<List<String>> ankiServerDeckNames(SyncClient client) async {
  final result = await _invoke(client, 'deckNames');
  if (result is! List) {
    throw const AnkiServerException(
        'Server answered deckNames in an unknown shape.');
  }
  return [for (final d in result) if (d is String) d];
}

/// Distinct cards answered in the last day, optionally scoped to [deck].
/// Same `findCards` query as [AnkiConnectClient.reviewsToday] so counts
/// mean the same thing on every platform.
Future<int> ankiServerReviewsToday(
  SyncClient client, {
  String? deck,
}) async {
  final result = await _invoke(client, 'findCards', {
    'query': AnkiConnectClient.scopedQuery(deck),
  });
  if (result is! List) {
    throw const AnkiServerException(
        'Server answered findCards in an unknown shape.');
  }
  return result.length;
}
