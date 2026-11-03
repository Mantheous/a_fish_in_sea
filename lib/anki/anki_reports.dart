import 'package:a_fish_in_sea/common/time/local_date.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';

/// Failure reading the add-on's reports. Messages are written for direct
/// display, matching the rest of the Anki UI.
class AnkiReportException implements Exception {
  final String message;
  const AnkiReportException(this.message);

  @override
  String toString() => 'AnkiReportException: $message';
}

/// One deck's totals for one local calendar day, as reported by the
/// add-on. [cards] counts distinct cards (the number goals use);
/// [reviews] counts answers, including repeats.
class AnkiReviewDay {
  final DateTime day;
  final String deck;
  final int cards;
  final int reviews;

  const AnkiReviewDay({
    required this.day,
    required this.deck,
    required this.cards,
    required this.reviews,
  });

  factory AnkiReviewDay.fromJson(Map<String, dynamic> json) {
    final row = tryFromJson(json);
    if (row == null) {
      throw const FormatException('Anki day needs a valid day and deck');
    }
    return row;
  }

  /// Lenient parse for list payloads: one malformed add-on row must not
  /// hide every other day in the response.
  static AnkiReviewDay? tryFromJson(Map<String, dynamic> json) {
    final day = DateTime.tryParse(json['day']?.toString() ?? '');
    final deck = json['deck']?.toString().trim() ?? '';
    if (day == null || deck.isEmpty) return null;
    return AnkiReviewDay(
      day: localDay(day),
      deck: deck,
      cards: ((json['cards'] as num?)?.toInt() ?? 0).clamp(0, 1000000000),
      reviews: ((json['reviews'] as num?)?.toInt() ?? 0).clamp(0, 1000000000),
    );
  }
}

/// Totals for one deck over the requested window, used by the deck
/// picker/help text in the goal editor and Settings.
class AnkiDeckSummary {
  final String name;
  final int cards;
  final int reviews;
  final DateTime? lastDay;

  const AnkiDeckSummary({
    required this.name,
    required this.cards,
    required this.reviews,
    required this.lastDay,
  });

  factory AnkiDeckSummary.fromJson(Map<String, dynamic> json) {
    final rawDay = json['last_day']?.toString();
    return AnkiDeckSummary(
      name: json['name']?.toString() ?? '',
      cards: ((json['cards'] as num?)?.toInt() ?? 0).clamp(0, 1000000000),
      reviews: ((json['reviews'] as num?)?.toInt() ?? 0).clamp(0, 1000000000),
      lastDay: rawDay == null ? null : DateTime.tryParse(rawDay),
    );
  }
}

/// Everything `GET /api/v1/anki/reviews` returns.
class AnkiReportData {
  final List<AnkiReviewDay> days;
  final List<AnkiDeckSummary> decks;
  final DateTime? lastReportAt;
  final String lastClient;

  /// Requested range, when known. A goal whose period starts before
  /// [windowStart] must not be rewritten from a partial sum.
  final DateTime? windowStart;
  final DateTime? windowEnd;

  const AnkiReportData({
    this.days = const [],
    this.decks = const [],
    this.lastReportAt,
    this.lastClient = '',
    this.windowStart,
    this.windowEnd,
  });

  static const empty = AnkiReportData();

  bool get isEmpty => days.isEmpty && lastReportAt == null;

  /// True when [start] falls inside the range this payload requested.
  bool covers(DateTime start) =>
      windowStart == null || !localDay(start).isBefore(windowStart!);

  factory AnkiReportData.fromJson(Map<String, dynamic> json) {
    final days = <AnkiReviewDay>[];
    final rawDays = json['days'];
    if (rawDays is List) {
      for (final item in rawDays) {
        if (item is! Map) continue;
        final row = AnkiReviewDay.tryFromJson(Map<String, dynamic>.from(item));
        if (row != null) days.add(row);
      }
    }
    final decks = <AnkiDeckSummary>[];
    final rawDecks = json['decks'];
    if (rawDecks is List) {
      for (final item in rawDecks) {
        if (item is! Map) continue;
        final deck = AnkiDeckSummary.fromJson(Map<String, dynamic>.from(item));
        if (deck.name.trim().isNotEmpty) decks.add(deck);
      }
    }
    final rawLast = json['last_report_at']?.toString();
    return AnkiReportData(
      days: days,
      decks: decks,
      lastReportAt: rawLast == null ? null : DateTime.tryParse(rawLast),
      lastClient: json['last_client']?.toString() ?? '',
    );
  }
}

String ankiIsoDay(DateTime day) {
  final local = localDay(day);
  final y = local.year.toString().padLeft(4, '0');
  final m = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// Reads the add-on's daily history. Requires a signed-in [client];
/// a 401 becomes a sign-in prompt instead of a transport dump.
Future<AnkiReportData> fetchAnkiReport(
  SyncClient client, {
  required DateTime start,
  required DateTime end,
}) async {
  dynamic body;
  try {
    body = await client.ankiReviews(
      start: ankiIsoDay(start),
      end: ankiIsoDay(end),
    );
  } on SyncException catch (e) {
    if (e.statusCode == 401) {
      throw const AnkiReportException(
        'Sign in to read Anki reports from the server.',
      );
    }
    throw AnkiReportException(
      e.message.isEmpty ? 'Server returned ${e.statusCode}' : e.message,
    );
  }
  if (body is! Map) {
    throw const AnkiReportException(
      'The server answered with an unknown Anki report shape.',
    );
  }
  // A report with no rows but a last_report_at is a valid "connected,
  // nothing to report yet" state; only reject a body that is not a map.
  final parsed = AnkiReportData.fromJson(Map<String, dynamic>.from(body));
  return AnkiReportData(
    days: parsed.days,
    decks: parsed.decks,
    lastReportAt: parsed.lastReportAt,
    lastClient: parsed.lastClient,
    windowStart: localDay(start),
    windowEnd: localDay(end),
  );
}

/// First day of the goal's current period, in local wall-clock terms.
///
/// Weekly windows honor the app's first-day-of-week setting. Biweekly
/// uses the current week plus the previous one, so a 14-day goal is
/// always full rather than resetting to 7 days at week start. A custom
/// period is anchored to [anchor] (the goal's creation day) and stepped
/// in whole [customPeriodDays] blocks, matching the budget model's
/// period windows.
///
/// A one-time goal passes its creation day via [anchor]; callers handle
/// that case before calling this. This function expects a non-null
/// [period].
DateTime ankiPeriodStart(
  TimeScale period, {
  int? customPeriodDays,
  DateTime? now,
  int firstDayOfWeek = 1,
  DateTime? anchor,
}) {
  final today = localDay(now ?? DateTime.now());
  switch (period) {
    case TimeScale.daily:
      return today;
    case TimeScale.weekly:
      return _weekStart(today, firstDayOfWeek);
    case TimeScale.biweekly:
      return shiftLocalDay(_weekStart(today, firstDayOfWeek), -7);
    case TimeScale.monthly:
      return DateTime(today.year, today.month, 1);
    case TimeScale.quarterly:
      final month = ((today.month - 1) ~/ 3) * 3 + 1;
      return DateTime(today.year, month, 1);
    case TimeScale.yearly:
      return DateTime(today.year, 1, 1);
    case TimeScale.custom:
      final days = (customPeriodDays ?? 30).clamp(1, 36500);
      final origin = localDay(anchor ?? today);
      final elapsed = localDayDistance(origin, today);
      final index = elapsed < 0 ? 0 : elapsed ~/ days;
      return shiftLocalDay(origin, index * days);
  }
}

DateTime _weekStart(DateTime day, int firstDayOfWeek) {
  final first = firstDayOfWeek.clamp(1, 7);
  final offset = (day.weekday - first + 7) % 7;
  return shiftLocalDay(day, -offset);
}

/// True when [deck] belongs to a goal on [goalDeck].
///
/// Blank means every deck. Anki's own `deck:` search includes subdecks,
/// so "Japanese" also matches "Japanese::Vocab". Comparison is
/// case-insensitive to match how people type deck names by hand.
bool ankiDeckMatches(String? goalDeck, String deck) {
  final goal = (goalDeck ?? '').trim().toLowerCase();
  if (goal.isEmpty) return true;
  final candidate = deck.trim().toLowerCase();
  return candidate == goal || candidate.startsWith('$goal::');
}

/// One goal's reading from the add-on's history.
class AnkiFacetCount {
  final int cards;
  final int reviews;

  /// Whether any report row matched the goal's deck at all. False means
  /// the add-on has never seen this deck; callers should keep the
  /// manual/last-cached count instead of overwriting it with zero.
  final bool hasData;

  /// Most recent matching day, for "last reported" copy.
  final DateTime? lastDay;

  const AnkiFacetCount({
    this.cards = 0,
    this.reviews = 0,
    this.hasData = false,
    this.lastDay,
  });
}

/// Sums matching rows in the window [start]..[end] (inclusive).
AnkiFacetCount ankiCountForFacet({
  required String? deckName,
  required DateTime start,
  required DateTime end,
  required AnkiReportData report,
}) {
  final from = localDay(start);
  final to = localDay(end);
  var cards = 0;
  var reviews = 0;
  var hasData = false;
  DateTime? lastDay;
  for (final row in report.days) {
    if (!ankiDeckMatches(deckName, row.deck)) continue;
    hasData = true;
    if (lastDay == null || row.day.isAfter(lastDay)) lastDay = row.day;
    if (row.day.isBefore(from) || row.day.isAfter(to)) continue;
    cards += row.cards;
    reviews += row.reviews;
  }
  return AnkiFacetCount(
    cards: cards,
    reviews: reviews,
    hasData: hasData,
    lastDay: lastDay,
  );
}

/// Per-node card counts for every readable Anki goal.
///
/// Only goals whose deck scope appears in the report are included. This
/// is what lets the sync service overwrite a stale cached count without
/// clobbering a manual fallback for a deck the add-on has never reported.
Map<String, int> ankiActualsForNodes(
  List<Node> nodes,
  AnkiReportData report, {
  DateTime? now,
  int firstDayOfWeek = 1,
}) {
  final moment = now ?? DateTime.now();
  final today = localDay(moment);
  final actuals = <String, int>{};
  for (final node in nodes) {
    final facet = node.anki;
    if (facet == null) continue;
    final start = facet.period == null
        ? localDay(node.createdAt)
        : ankiPeriodStart(
            facet.period!,
            customPeriodDays: facet.customPeriodDays,
            now: moment,
            firstDayOfWeek: firstDayOfWeek,
            anchor: node.createdAt,
          );
    // A one-time or long custom goal older than the requested window
    // cannot be summed completely; keep its cached count instead of
    // silently replacing it with a partial total.
    if (!report.covers(start)) continue;
    final count = ankiCountForFacet(
      deckName: facet.deckName,
      start: start,
      end: today,
      report: report,
    );
    if (count.hasData) actuals[node.id] = count.cards;
  }
  return actuals;
}
