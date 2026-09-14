import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';

/// Feed-import heuristics for unified nodes. Moved from TaskCubit so feed
/// homework shadows land in the node DAG instead of the retired task list.
///
/// Learning Suite merges two different things into one iCal feed, with no
/// machine-readable distinction (unlike Canvas `event-assignment-*` UIDs):
///
/// - Assignment/quiz/exam objects (graded). These either carry a
///   DTSTART..DTEND open window or are due-date-only items with an
///   empty DESCRIPTION.
/// - Schedule/commentary entries for a class day: lecture topics, prep
///   notes, daily nudges. These always echo the day's text in
///   DESCRIPTION, so the SUMMARY is just a truncated prefix of it.
///
/// Only the first group becomes nodes. Title keywords are deliberately NOT
/// consulted: topic titles contain words like "post" (Postmodern) while
/// real items like "Unit 3 Quote Point Tracker" contain none.

const int nodeImportLookbackDays = 7;

bool looksLikeLearningSuiteAssignment(String subject, String? notes) {
  final title = subject.trim();
  // IcalService substitutes 'Untitled' for blank schedule lines.
  if (title.isEmpty || title == 'Untitled') return false;
  final body = (notes ?? '').trim();
  if (body.isEmpty) return true;
  // The iCal parser hands back SUMMARY raw but DESCRIPTION unescaped, so
  // normalize `\,` / `\n` escapes on both sides before comparing.
  // Whitespace is squashed too: iCal folding can drop the space at the
  // wrap point ("DDQuote Points"), breaking a naive prefix check.
  String normalize(String s) =>
      _squashWhitespace(_unescapeIcalText(s));
  final a = normalize(title);
  final b = normalize(body);
  if (b.startsWith(a) || a.startsWith(b)) return false;
  // SUMMARY truncates around ~70 chars; match the head as a fallback.
  if (a.length > 50 && b.startsWith(a.substring(0, 50))) return false;
  if (b.length > 50 && a.startsWith(b.substring(0, 50))) return false;
  return true;
}

/// Unescapes iCal TEXT values (`\,` -> `,`, `\n` -> newline, ...).
String _unescapeIcalText(String s) => s.replaceAllMapped(
      RegExp(r'\\(.)', dotAll: true),
      (m) => switch (m.group(1)) {
        'n' || 'N' => '\n',
        _ => m.group(1)!,
      },
    );

String _squashWhitespace(String s) => s.replaceAll(RegExp(r'\s+'), '');

/// Whether a feed event qualifies as a node (same rule
/// [NodeCubit.importFromFeed] uses to create homework nodes). Extracted so
/// [FeedCubit] can mark [PlannerEvent.isTask] with the identical heuristic.
bool isNodeCandidate(PlannerEvent event, Feed feed, DateTime now) {
  final cutoff =
      now.subtract(const Duration(days: nodeImportLookbackDays));
  // Windows open early: judge staleness by the due end, not the open start.
  if (event.end.isBefore(cutoff)) return false;
  if (feed.kind == FeedKind.canvas &&
      !(event.sourceUid?.startsWith('event-assignment-') ?? false)) {
    return false;
  }
  if (feed.kind == FeedKind.learningSuite &&
      !looksLikeLearningSuiteAssignment(event.subject, event.notes)) {
    return false;
  }
  return true;
}
