import 'package:equatable/equatable.dart';

import 'feed.dart';
import 'planner_event.dart';

/// Stable ids for the calendar visibility tree.
///
/// Groups are the nestable parents ("Google" contains each Google calendar,
/// "Homework" contains each class, "Finance" will contain finance calendars
/// added later). Leaves are the individually toggleable calendars.
///
/// Leaf ids reuse [Feed.id] wherever a calendar maps 1:1 to a feed so
/// renames don't orphan visibility prefs. Canvas is the exception: one feed
/// fans out to many classes, so its leaves are `<feedId>::<classLabel>`.
const String calendarGroupPersonal = 'group:personal';
const String calendarGroupGoogle = 'group:google';
const String calendarGroupHomework = 'group:homework';
const String calendarGroupFinance = 'group:finance';
const String calendarGroupOther = 'group:other';

/// Leaf id for personal ("This device") events with no [PlannerEvent.feedId].
const String personalCalendarId = 'personal';

/// Separator between a Canvas feed id and its class label in a leaf id.
const String canvasLeafSeparator = '::';

/// Prefix for finance calendars added in the future (`finance:<id>`).
const String financeCalendarPrefix = 'finance:';

/// Ordered group ids for the picker UI. All groups are always shown (even
/// when empty) so future calendars (notably Finance) have a stable home.
const List<String> calendarGroupOrder = [
  calendarGroupPersonal,
  calendarGroupGoogle,
  calendarGroupHomework,
  calendarGroupFinance,
  calendarGroupOther,
];

String calendarGroupTitle(String groupId) => switch (groupId) {
      calendarGroupPersonal => 'On this device',
      calendarGroupGoogle => 'Google',
      calendarGroupHomework => 'Homework',
      calendarGroupFinance => 'Finance',
      calendarGroupOther => 'Other',
      _ => 'Other',
    };

/// Maps an event to its toggleable leaf calendar.
///
/// - `feedId == null` → [personalCalendarId].
/// - Google / Learning Suite / Other → the feed id.
/// - Canvas with a class label → `<feedId>::<classLabel>` so each course
///   toggles independently; without a label it falls back to the feed id.
/// - Unknown feed (deleted?) → the raw feed id so the event still has a
///   stable leaf instead of vanishing.
String calendarLeafIdForEvent(PlannerEvent event, Feed? feed) {
  final feedId = event.feedId;
  if (feedId == null || feedId.isEmpty) return personalCalendarId;
  if (feed == null) return feedId;
  if (feed.kind == FeedKind.canvas) {
    final label = event.classLabel?.trim() ?? '';
    if (label.isEmpty) return feed.id;
    return '${feed.id}$canvasLeafSeparator$label';
  }
  return feed.id;
}

/// Group that owns a feed. Canvas + Learning Suite are classes → Homework.
/// `finance:*` feed ids (future) → Finance.
String groupIdForFeed(Feed feed) {
  if (feed.id.startsWith(financeCalendarPrefix)) return calendarGroupFinance;
  return switch (feed.kind) {
    FeedKind.google => calendarGroupGoogle,
    FeedKind.canvas => calendarGroupHomework,
    FeedKind.learningSuite => calendarGroupHomework,
    FeedKind.other => calendarGroupOther,
  };
}

/// Group that owns a leaf id. Falls back to prefix guessing when the feed
/// is gone so stale prefs still resolve to the right group.
String groupIdForLeaf(String leafId, Feed? feed) {
  if (leafId == personalCalendarId) return calendarGroupPersonal;
  if (leafId.startsWith(financeCalendarPrefix)) return calendarGroupFinance;
  if (feed != null) {
    // Canvas class leaves resolve via their parent feed.
    if (leafId.contains(canvasLeafSeparator)) return calendarGroupHomework;
    return groupIdForFeed(feed);
  }
  final baseId = leafId.split(canvasLeafSeparator).first;
  if (baseId.startsWith('gcal:')) return calendarGroupGoogle;
  if (baseId.startsWith(financeCalendarPrefix)) return calendarGroupFinance;
  if (leafId.contains(canvasLeafSeparator)) return calendarGroupHomework;
  return calendarGroupOther;
}

/// A single toggleable calendar.
class CalendarLeaf extends Equatable {
  final String id;
  final String groupId;
  final String title;
  final int? colorValue;
  final int eventCount;

  const CalendarLeaf({
    required this.id,
    required this.groupId,
    required this.title,
    this.colorValue,
    this.eventCount = 0,
  });

  @override
  List<Object?> get props => [id, groupId, title, colorValue, eventCount];
}

/// A nestable parent (Google / Homework / Finance / …) holding leaves.
class CalendarGroup extends Equatable {
  final String id;
  final String title;
  final List<CalendarLeaf> leaves;

  const CalendarGroup({
    required this.id,
    required this.title,
    this.leaves = const [],
  });

  @override
  List<Object?> get props => [id, title, leaves];
}

/// Builds the nested visibility tree from current feeds + events.
///
/// - Personal group always has the single "This device" leaf.
/// - Google/Other groups have one leaf per feed (even before first sync).
/// - Homework fans Canvas feeds out per class label found in events; a
///   feed-level fallback leaf covers unlabeled events and pre-sync feeds.
/// - Finance collects future `finance:*` feeds/leaves; empty for now but
///   always present so later calendars slot in without a migration.
List<CalendarGroup> buildCalendarTree({
  required List<Feed> feeds,
  required List<PlannerEvent> events,
}) {
  final feedById = {for (final f in feeds) f.id: f};

  final counts = <String, int>{};
  for (final event in events) {
    final leafId = calendarLeafIdForEvent(event, feedById[event.feedId]);
    counts[leafId] = (counts[leafId] ?? 0) + 1;
  }

  final personalCount = counts[personalCalendarId] ?? 0;
  final personal = CalendarGroup(
    id: calendarGroupPersonal,
    title: calendarGroupTitle(calendarGroupPersonal),
    leaves: [
      CalendarLeaf(
        id: personalCalendarId,
        groupId: calendarGroupPersonal,
        title: 'My events',
        colorValue: 0xFF6B8F8A,
        eventCount: personalCount,
      ),
    ],
  );

  List<CalendarLeaf> leavesForKind(
    bool Function(Feed) matches, {
    bool fanOutCanvas = false,
  }) {
    final out = <CalendarLeaf>[];
    final matching = feeds.where(matches).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    for (final feed in matching) {
      if (fanOutCanvas && feed.kind == FeedKind.canvas) {
        final labels = <String>{};
        for (final event in events) {
          if (event.feedId != feed.id) continue;
          final label = event.classLabel?.trim() ?? '';
          if (label.isNotEmpty) labels.add(label);
        }
        final sorted = labels.toList()..sort();
        for (final label in sorted) {
          final leafId = '${feed.id}$canvasLeafSeparator$label';
          out.add(CalendarLeaf(
            id: leafId,
            groupId: calendarGroupHomework,
            title: label,
            colorValue: courseColor(label).toARGB32(),
            eventCount: counts[leafId] ?? 0,
          ));
        }
        final fallbackCount = counts[feed.id] ?? 0;
        final hasUnlabeled = events.any((e) =>
            e.feedId == feed.id &&
            (e.classLabel == null || e.classLabel!.trim().isEmpty));
        // Keep the feed visible pre-sync and as a home for unlabeled
        // events; hide the fallback when every event has a class leaf.
        if (sorted.isEmpty || hasUnlabeled || fallbackCount > 0) {
          out.add(CalendarLeaf(
            id: feed.id,
            groupId: calendarGroupHomework,
            title: sorted.isEmpty ? feed.name : '${feed.name} (other)',
            colorValue: feed.colorValue,
            eventCount: fallbackCount,
          ));
        }
      } else {
        out.add(CalendarLeaf(
          id: feed.id,
          groupId: groupIdForFeed(feed),
          title: feed.name,
          colorValue: feed.colorValue,
          eventCount: counts[feed.id] ?? 0,
        ));
      }
    }
    return out;
  }

  final google = CalendarGroup(
    id: calendarGroupGoogle,
    title: calendarGroupTitle(calendarGroupGoogle),
    leaves: leavesForKind((f) => f.kind == FeedKind.google),
  );

  final homework = CalendarGroup(
    id: calendarGroupHomework,
    title: calendarGroupTitle(calendarGroupHomework),
    leaves: leavesForKind(
      (f) => f.kind == FeedKind.canvas || f.kind == FeedKind.learningSuite,
      fanOutCanvas: true,
    ),
  );

  final financeFeeds =
      feeds.where((f) => f.id.startsWith(financeCalendarPrefix)).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
  final financeLeaves = <CalendarLeaf>[
    for (final feed in financeFeeds)
      CalendarLeaf(
        id: feed.id,
        groupId: calendarGroupFinance,
        title: feed.name,
        colorValue: feed.colorValue,
        eventCount: counts[feed.id] ?? 0,
      ),
    // Events already tagged finance:* without a feed yet (future-proof).
    for (final leafId in counts.keys.where((id) =>
        id.startsWith(financeCalendarPrefix) &&
        !financeFeeds.any((f) => f.id == id)))
      CalendarLeaf(
        id: leafId,
        groupId: calendarGroupFinance,
        title: leafId.substring(financeCalendarPrefix.length),
        eventCount: counts[leafId] ?? 0,
      ),
  ];
  final finance = CalendarGroup(
    id: calendarGroupFinance,
    title: calendarGroupTitle(calendarGroupFinance),
    leaves: financeLeaves,
  );

  final other = CalendarGroup(
    id: calendarGroupOther,
    title: calendarGroupTitle(calendarGroupOther),
    leaves: leavesForKind((f) =>
        f.kind == FeedKind.other &&
        !f.id.startsWith(financeCalendarPrefix)),
  );

  return [personal, google, homework, finance, other];
}
