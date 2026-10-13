/// Manual-stats fallback for platforms that cannot reach AnkiConnect
/// (web browsers) and for mobile-only users with no desktop Anki.
///
/// Format is deliberately tiny — one count per line, so a user can paste
/// from anywhere without exporting files:
///
/// ```text
/// # lines starting with # and blank lines are ignored
/// 42                  <- 42 reviews across all decks
/// Japanese, 30        <- 30 reviews in the "Japanese" deck
/// Medicine: 12        <- colon works too (deck names use :: themselves)
/// ```
///
/// A bare number counts toward every deck. [AnkiImportResult.total] is the
/// sum of every line; [byDeck] breaks it down (`'*'` = unscoped lines).
/// Anything else throws [FormatException] naming the line.
class AnkiImportResult {
  final Map<String, int> byDeck;
  final int total;

  const AnkiImportResult({required this.byDeck, required this.total});
}

AnkiImportResult parseAnkiReviewCounts(String text) {
  final byDeck = <String, int>{};
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    String deck = '*';
    String countPart = line;
    final comma = line.lastIndexOf(',');
    if (comma >= 0) {
      deck = line.substring(0, comma).trim();
      countPart = line.substring(comma + 1).trim();
    } else {
      final colon = RegExp(r'^(.*):\s+(\S+)\s*$').firstMatch(line);
      if (colon != null) {
        deck = colon.group(1)!.trim();
        countPart = colon.group(2)!.trim();
      }
    }
    final count = int.tryParse(countPart);
    if (deck.isEmpty || count == null || count < 0) {
      throw FormatException(
          'Line ${i + 1}: expected a count like "42" or "Deck, 42" — got "$line".');
    }
    byDeck.update(deck, (v) => v + count, ifAbsent: () => count);
  }
  if (byDeck.isEmpty) {
    throw const FormatException(
        'No counts found — paste something like "42" or "Deck, 42".');
  }
  return AnkiImportResult(
    byDeck: byDeck,
    total: byDeck.values.fold(0, (a, b) => a + b),
  );
}
