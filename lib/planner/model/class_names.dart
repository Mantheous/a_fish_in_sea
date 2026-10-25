import 'feed.dart';

/// Id prefixes local calendars use for their [Feed.id]s (see the feed
/// creators in `feed_manager.dart` / Google connect). A class key that still
/// looks like one of these after the feed lookup is a stale reference — the
/// class was removed — not a course name to show.
const List<String> classFeedIdPrefixes = ['feed:', 'gcal:', 'finance:'];

/// Display name for a homework class key.
///
/// A key is either a Canvas course code (`Node.classLabel`, e.g.
/// "STAT 230-002") or a raw [Feed.id] for feeds whose events carry no
/// per-event label (Learning Suite, Other). Raw ids look like
/// `feed:1789249594268000`; resolve them through [feeds] so the UI keeps
/// showing the class name the user typed.
String classNameFor(String key, Iterable<Feed> feeds) {
  if (key.isEmpty) return key;
  for (final feed in feeds) {
    if (feed.id == key) return feed.name;
  }
  for (final prefix in classFeedIdPrefixes) {
    if (key.startsWith(prefix)) return 'Unknown class';
  }
  return key;
}
