/// Template keys for repeating homework types.
///
/// A class feed (Canvas `event-assignment-*` UIDs, Learning Suite items)
/// carries one VEVENT per assignment — there is no recurrence rule and no
/// server-side "type" field on the items the app reads today. (Canvas does
/// have instructor-defined assignment groups with stable ids behind
/// `GET /courses/:id/assignment_groups`, which would turn classification
/// into a lookup; the planner/items endpoint the app uses doesn't return
/// them, so that stays a follow-up.) Until then, grouping is a normalized
/// template key, deliberately stricter than substring matching:
///
/// - Scoped to one feed (course). `Quiz` in MATH 290 never matches `Quiz`
///   in STAT 230.
/// - Lowercased, whitespace-collapsed, with trailing numeric / section /
///   date markers stripped iteratively (`Video Quiz 3.1` and
///   `Video Quiz 3.4b` both become `video quiz`; `Homework 42` becomes
///   `homework`). Exact repeats (`Exit Quiz`) group naturally.
/// - Matching at apply time is exact key equality, so `Quiz` never
///   swallows `Quiz Retake`.
/// - Candidates surface only with 3+ occurrences and a roughly regular
///   cadence, and rules are always user-confirmed — nothing auto-applies.
///
/// Pure functions only: no Flutter, no cubits, fully unit-testable.
library;

/// Normalize one assignment title to its repeating-type template key.
String assignmentTemplateKey(String title) {
  var s = title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  if (s.isEmpty) return s;
  final fallback = s;
  var prev = '';
  for (var i = 0; i < 4 && s != prev; i++) {
    prev = s;
    s = _stripOneTrailingMarker(s).trim();
    if (s.isEmpty) return fallback;
  }
  return s;
}

final _monthNames =
    'jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec';

/// Ordered longest-first so one pass strips one suffix layer.
final List<RegExp> _trailingMarkers = [
  // Trailing parenthetical/bracket remark carrying a number or date:
  // "Lab 2 (Ch 3)", "Quiz [week 4]". Requires a digit/month inside so
  // meaningful remarks like "Quiz (Practice)" survive.
  RegExp(
      '\\s*[\\(\\[][^()\\[\\]]*(\\d|$_monthNames)[^()\\[\\]]*[\\)\\]]\$'),
  // Weekday + month + day: "In Class MWF Sep 04", "Lecture Fri Oct 3".
  RegExp(
      '\\s+(mon|tue|wed|thu|fri|sat|sun)[a-z]*\\s+($_monthNames)[a-z]*\\s+\\d{1,2}([a-z]{2})?(\\s+\\d{2,4})?\$'),
  // Month + day (+ year): "Sep 04", "October 3 2026".
  RegExp(
      '\\s+($_monthNames)[a-z]*\\s+\\d{1,2}([a-z]{2})?(\\s+\\d{2,4})?\$'),
  // Numeric date: "9/04", "10-03-2026".
  RegExp('\\s+\\d{1,2}[/-]\\d{1,2}([/-]\\d{2,4})?\$'),
  // Section words + number + anything after: "Ch 3", "Week 4 reading",
  // "Unit 3 Quote Point Tracker", "HW #5", "Problem No. 2".
  RegExp(
      '\\s+(ch|chapter|week|wk|day|unit|section|sec|module|mod|lesson|part|pt|no|number)\\b\\.?\\s*#?\\d+.*\$'),
  // Version / hash numbers: "v2", "#12", "3.1", "12.4b", "42", "3a".
  RegExp('\\s+v\\d+(\\.\\d+)*[a-z]?\$'),
  RegExp('\\s+#\\d+[a-z]?\$'),
  RegExp('\\s+\\d+(\\.\\d+)+[a-z]?\$'),
  RegExp('\\s+\\d+[a-z]?\$'),
];

String _stripOneTrailingMarker(String s) {
  for (final pattern in _trailingMarkers) {
    final stripped = s.replaceFirst(pattern, '');
    if (stripped != s) return stripped;
  }
  return s;
}

/// One homework item's grouping inputs. Plain data (not [Node]) so the
/// planner model stays decoupled from the node DAG.
class TemplateSample {
  final String feedId;
  final String? classLabel;
  final String title;
  final DateTime? due;

  const TemplateSample({
    required this.feedId,
    required this.title,
    this.classLabel,
    this.due,
  });
}

/// A detected repeating type within one feed.
class AssignmentGroup {
  final String feedId;
  final String? classLabel;
  final String templateKey;

  /// Shortest member title: closest to the human base name.
  final String displayName;
  final int count;

  /// Median gap between consecutive dues in days, when determinable.
  final double? medianGapDays;

  /// 3+ occurrences on a roughly regular cadence. Pairs are shown as
  /// candidates but are not "repeating" yet.
  final bool isRepeating;

  const AssignmentGroup({
    required this.feedId,
    required this.templateKey,
    required this.displayName,
    required this.count,
    this.classLabel,
    this.medianGapDays,
    required this.isRepeating,
  });
}

/// Group [samples] by feed + template key, most members first. Only
/// groups with 2+ members are returned; use [AssignmentGroup.isRepeating]
/// to tell repeating types (>= 3 + regular cadence) from pairs.
List<AssignmentGroup> detectRepeatingGroups(Iterable<TemplateSample> samples) {
  final byKey = <String, List<TemplateSample>>{};
  for (final s in samples) {
    final key = assignmentTemplateKey(s.title);
    if (key.isEmpty) continue;
    byKey.putIfAbsent('${s.feedId}|$key', () => []).add(s);
  }
  final out = <AssignmentGroup>[];
  for (final entry in byKey.entries) {
    if (entry.value.length < 2) continue;
    final members = entry.value;
    final sep = entry.key.indexOf('|');
    final feedId = entry.key.substring(0, sep);
    final templateKey = entry.key.substring(sep + 1);
    final dues = [
      for (final m in members)
        if (m.due != null) m.due!,
    ]..sort();
    double? medianGap;
    var regular = false;
    if (dues.length >= 3) {
      final gaps = <double>[];
      for (var i = 1; i < dues.length; i++) {
        gaps.add(dues[i].difference(dues[i - 1]).inHours / 24.0);
      }
      gaps.sort();
      medianGap = gaps[gaps.length ~/ 2];
      final spread = gaps.last - gaps.first;
      // Weekly quizzes arrive every 7 days give or take a day; a 1-day
      // and a 30-day gap are not a cadence even though both "average".
      regular = spread <= (medianGap < 6 ? 3 : medianGap / 2);
    }
    var display = members.first.title.trim();
    for (final m in members) {
      if (m.title.trim().length < display.length) display = m.title.trim();
    }
    out.add(AssignmentGroup(
      feedId: feedId,
      classLabel: members.first.classLabel,
      templateKey: templateKey,
      displayName: display,
      count: members.length,
      medianGapDays: medianGap,
      isRepeating: members.length >= 3 && regular,
    ));
  }
  out.sort((a, b) {
    if (a.isRepeating != b.isRepeating) return a.isRepeating ? -1 : 1;
    return b.count.compareTo(a.count);
  });
  return out;
}

/// Human cadence hint for the rules sheet ("roughly every 7 days").
String? describeCadence(double? medianGapDays) {
  if (medianGapDays == null) return null;
  final days = medianGapDays.round();
  if (days <= 1) return 'about daily';
  if (days == 7) return 'about weekly';
  if (days == 14) return 'about every 2 weeks';
  if (days >= 28 && days <= 31) return 'about monthly';
  return 'roughly every $days days';
}

// ── Feed-truth due math ──────────────────────────────────────────────
// Imported homework nodes keep the feed window in schedule.start/end and
// carry the (possibly rule-shifted) deadline in schedule.due. The base
// (unshifted) due is re-derivable from the node's own window with the
// same rule importFromFeed uses, so bulk apply/revert can tell
// "never shifted" from "shifted by rule X" from "hand-edited" without
// storing any extra per-node state.

/// Base due for an imported window: Learning Suite open..due windows
/// (all-day, span > 1 day) are due at the inclusive end of the window,
/// everything else at the start. Mirrors NodeCubit.importFromFeed.
///
/// All-day VEVENT DTENDs are exclusive per RFC 5545 (a window
/// DTSTART:20261012 DTEND:20261015 covers Oct 12–14, due Oct 14), so the
/// base is end minus one day. Timed windows keep the exact end instant.
DateTime? assignmentBaseDue({
  required DateTime? start,
  required DateTime? end,
  required bool allDay,
}) {
  if (start == null || end == null) return null;
  final isWindow =
      allDay && end.difference(start) > const Duration(days: 1);
  if (!isWindow) return start;
  return end.subtract(const Duration(days: 1));
}

/// How far [due] sits from [base], in whole days. Null when unknown.
int? assignmentShiftOf({required DateTime? due, required DateTime? base}) {
  if (due == null || base == null) return null;
  return due.difference(base).inDays;
}
