import 'syllabus_draft.dart';

/// Offline heuristic fallback for syllabus → tasks.
///
/// Handles explicit dated lines well ("HW 3 due Oct 12", "Midterm: Sep 20",
/// "10/12 - Problem Set 4"). Vague prose without dates is left to the LLM
/// path ([SyllabusLlmClient]); this parser only emits what it can ground.
List<SyllabusDraft> parseSyllabusLocally(String text, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final drafts = <SyllabusDraft>[];
  final seen = <String>{};

  final lines = text
      .split(RegExp(r'\r?\n'))
      // Also split on bullet boundaries when a syllabus is one long blob.
      .expand((line) => line.split(RegExp(r'\s*[•·▪▪️]+\s*')))
      .map((line) => line.trim())
      .where((line) => line.length > 3)
      .toList();

  for (final rawLine in lines) {
    final line = _stripBullet(rawLine);
    if (line.length < 4) continue;
    if (_looksLikeHeader(line)) continue;

    final due = _extractDate(line, reference);
    final hasSignal = _hasAssignmentSignal(line);

    // Require either a grounded date or a strong assignment keyword —
    // this keeps lecture topics / office-hours prose out.
    if (due == null && !hasSignal) continue;
    // Date-only fragments ("Oct 12") with no task content are useless.
    if (due != null && !hasSignal && _isMostlyDate(line)) continue;

    var title = _cleanTitle(line);
    if (title.length < 3) continue;
    if (title.length > 140) title = '${title.substring(0, 137)}...';

    final key = '${title.toLowerCase()}|${due?.toIso8601String() ?? ''}';
    if (!seen.add(key)) continue;

    drafts.add(SyllabusDraft(title: title, due: due));
    if (drafts.length >= 100) break;
  }

  drafts.sort((a, b) {
    if (a.due == null && b.due == null) return 0;
    if (a.due == null) return 1;
    if (b.due == null) return -1;
    return a.due!.compareTo(b.due!);
  });
  return drafts;
}

final _bulletPrefix = RegExp(r'^(\d+[.)]\s+|[-*–—]+\s+|#+\s+)');

String _stripBullet(String line) => line.replaceFirst(_bulletPrefix, '').trim();

final _headerPattern = RegExp(
  r'^(syllabus|course\s+(description|overview|objectives|policies)|schedule(\s+of\s+\w+)?|grading(\s+policy)?|office\s+hours|contact|instructor|textbook|required\s+materials|academic\s+integrity|attendance(\s+policy)?|late\s+work|calendar)\s*:?\s*$',
  caseSensitive: false,
);

bool _looksLikeHeader(String line) {
  if (line.length < 60 && _headerPattern.hasMatch(line)) return true;
  return false;
}

final _assignmentKeywords = RegExp(
  r'\b(hw|homework|assignment|problem\s*set|pset|quiz|exam|midterm|final|test|project|paper|essay|lab|reading|report|presentation|worksheet|checkpoint|milestone|deliverable|draft|portfolio|case\s*study)\b',
  caseSensitive: false,
);

bool _hasAssignmentSignal(String line) => _assignmentKeywords.hasMatch(line);

final _monthNames = <String, int>{
  'january': 1, 'jan': 1,
  'february': 2, 'feb': 2,
  'march': 3, 'mar': 3,
  'april': 4, 'apr': 4,
  'may': 5,
  'june': 6, 'jun': 6,
  'july': 7, 'jul': 7,
  'august': 8, 'aug': 8,
  'september': 9, 'sept': 9, 'sep': 9,
  'october': 10, 'oct': 10,
  'november': 11, 'nov': 11,
  'december': 12, 'dec': 12,
};

final _monthDayPattern = RegExp(
  r'\b(january|february|march|april|may|june|july|august|september|sept|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)\w*\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b',
  caseSensitive: false,
);
final _numericMdPattern = RegExp(r'\b(\d{1,2})[/-](\d{1,2})(?:[/-](\d{2,4}))?\b');
final _isoPattern = RegExp(r'\b(\d{4})-(\d{1,2})-(\d{1,2})\b');

DateTime? _extractDate(String line, DateTime reference) {
  final iso = _isoPattern.firstMatch(line);
  if (iso != null) {
    final y = int.tryParse(iso.group(1)!);
    final m = int.tryParse(iso.group(2)!);
    final d = int.tryParse(iso.group(3)!);
    if (y != null && m != null && d != null && m >= 1 && m <= 12 && d >= 1 && d <= 31) {
      return DateTime(y, m, d);
    }
  }
  final md = _monthDayPattern.firstMatch(line);
  if (md != null) {
    final month = _monthNames[md.group(1)!.toLowerCase().replaceAll('.', '')];
    final day = int.tryParse(md.group(2)!);
    if (month != null && day != null && day >= 1 && day <= 31) {
      return _withInferredYear(month, day, reference);
    }
  }
  final num = _numericMdPattern.firstMatch(line);
  if (num != null) {
    var m = int.tryParse(num.group(1)!);
    var d = int.tryParse(num.group(2)!);
    final yRaw = num.group(3);
    if (m != null && d != null) {
      if (yRaw != null) {
        var y = int.tryParse(yRaw)!;
        if (y < 100) y += 2000;
        if (m >= 1 && m <= 12 && d >= 1 && d <= 31) return DateTime(y, m, d);
        return null;
      }
      // Disambiguate 10/12 vs 12/10: assume month-first (US syllabi).
      if (m >= 1 && m <= 12 && d >= 1 && d <= 31) {
        return _withInferredYear(m, d, reference);
      }
    }
  }
  return null;
}

/// Picks a year for a month/day: current year, rolling forward when the
/// date is stale (>90 days past) so fall syllabi pasted in spring still
/// land in the future.
DateTime _withInferredYear(int month, int day, DateTime reference) {
  var date = DateTime(reference.year, month, day);
  if (date.isBefore(reference.subtract(const Duration(days: 90)))) {
    date = DateTime(reference.year + 1, month, day);
  }
  return date;
}

final _datePhrasePattern = RegExp(
  r'\s*(due|by|on|deadline)\s*:?\s*'
  r'((january|february|march|april|may|june|july|august|september|sept|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec)\w*\.?\s+\d{1,2}(?:st|nd|rd|th)?|\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?|\d{4}-\d{1,2}-\d{1,2})',
  caseSensitive: false,
);

String _cleanTitle(String line) {
  var out = line.replaceAll(_datePhrasePattern, ' ');
  // Trailing parenthesized date "(Oct 12)" left behind.
  out = out.replaceAll(RegExp(r'\(\s*\)'), ' ');
  out = out.replaceAll(RegExp(r'\s{2,}'), ' ');
  out = out.trim();
  // Strip leading "Due ..." / trailing cruft.
  out = out.replaceFirst(RegExp(r'^(due|deadline)\s*:?\s*', caseSensitive: false), '');
  out = out.replaceFirst(RegExp(r'[\s:–—-]+\s*$'), '');
  // Title-case normalization is left alone; just fix spacing around colon.
  return out.trim();
}

/// True when the line is basically just a date ("Oct 12", "10/12 - ").
bool _isMostlyDate(String line) {
  final stripped = line
      .replaceAll(_monthDayPattern, '')
      .replaceAll(_numericMdPattern, '')
      .replaceAll(_isoPattern, '')
      .replaceAll(RegExp(r'[\s:–—\-.,()]+'), '');
  return stripped.length < 8;
}
