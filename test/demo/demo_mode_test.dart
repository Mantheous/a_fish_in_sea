import 'package:a_fish_in_sea/demo/demo_data.dart';
import 'package:a_fish_in_sea/demo/demo_mode.dart';
import 'package:a_fish_in_sea/demo/demo_storage.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DemoMode starts inactive and is never persisted', () {
    expect(DemoMode.isActive, isFalse);
  });

  test('DemoStorage is an ephemeral in-memory box', () async {
    final storage = DemoStorage();
    expect(storage.read('k'), isNull);
    await storage.write('k', {'a': 1});
    expect(storage.read('k'), {'a': 1});
    await storage.delete('k');
    expect(storage.read('k'), isNull);
    await storage.write('a', 1);
    await storage.write('b', 2);
    await storage.clear();
    expect(storage.read('a'), isNull);
  });

  test('demo feeds cover every integration kind', () {
    final feeds = DemoData.feeds(DateTime.now());
    final kinds = feeds.map((f) => f.kind.name).toSet();
    expect(
      kinds,
      containsAll({'canvas', 'learningSuite', 'google', 'other'}),
    );
    expect(
      feeds.map((f) => f.id),
      containsAll([
        DemoData.canvasFeedId,
        DemoData.learningSuiteFeedId,
        DemoData.googleFeedId,
        DemoData.communityFeedId,
      ]),
    );
  });

  test('demo feed events use real importer conventions', () {
    final now = DateTime.now();
    final events = DemoData.feedEvents(now);
    final homework = events
        .where((e) => (e.sourceUid ?? '').startsWith('event-assignment-'))
        .toList();
    expect(homework.length, greaterThanOrEqualTo(3));
    // Class sessions stay calendar-only (no assignment UID).
    expect(
      events.any((e) =>
          e.feedId == DemoData.canvasFeedId &&
          !(e.sourceUid ?? '').startsWith('event-assignment-')),
      isTrue,
    );
    // A Google event is remote-editable content (feed + source uid).
    expect(
      events.any((e) =>
          e.feedId == DemoData.googleFeedId && e.sourceUid != null),
      isTrue,
    );
  });

  test('demo homework nodes link to their events', () {
    final now = DateTime.now();
    final events = DemoData.feedEvents(now);
    final nodes = DemoData.nodes(now);
    final byId = {for (final e in events) e.id: e};
    final homework = nodes.where((n) => n.sourceEventId != null).toList();
    expect(homework.length, greaterThanOrEqualTo(4));
    for (final node in homework) {
      expect(byId[node.sourceEventId], isNotNull,
          reason: 'node ${node.id} has no backing event');
      expect(node.classId, isNotNull);
    }
    // Money nodes for the ledger.
    expect(nodes.any((n) => n.money != null), isTrue);
    // Round-trips through the sync envelope.
    for (final node in nodes) {
      expect(Node.fromJson(node.toJson()).id, node.id);
    }
    for (final event in events) {
      expect(PlannerEvent.fromJson(event.toJson()).id, event.id);
    }
  });

  test('demo Canvas submissions heal one item, never the bare-graded one', () {
    final submissions = DemoData.canvasSubmissions();
    final doneIds = {
      for (final s in submissions)
        if (s.countsAsDone) s.assignmentId,
    };
    expect(doneIds, containsAll({101, 103}));
    expect(doneIds, isNot(contains(102)));
  });

  test('demo Plaid payloads parse through the real importers', () {
    final now = DateTime.now();
    final raw = DemoData.plaidTransactions(now);
    expect(raw.length, greaterThanOrEqualTo(5));
    final parsed = raw.map((j) => Transaction.fromPlaid(j)).toList();
    expect(parsed.every((t) => t.id.isNotEmpty), isTrue);
    // Spending is negative, income positive after the sign flip.
    expect(parsed.any((t) => t.amount < 0), isTrue);
    expect(parsed.any((t) => t.amount > 0), isTrue);
    // Balance helper shape matches what PlaidCubit sums.
    final balance = DemoData.plaidBalance();
    expect((balance['accounts'] as List).length, 2);
    final seeded = DemoData.transactions(now);
    expect(seeded.any((t) => t.assignedNodeId != null), isTrue);
  });

  test('demo contacts, calendars, syllabus and inbox are populated', () {
    expect(DemoData.googleContacts().length, greaterThanOrEqualTo(4));
    expect(DemoData.googleCalendars().length, 2);
    expect(DemoData.syllabusDrafts(DateTime.now()).length, 3);
    expect(DemoData.places().length, 3);
    expect(DemoData.reportedEntries(DateTime.now()).isNotEmpty, isTrue);
    expect(DemoData.trackedPoints(DateTime.now()).length, greaterThanOrEqualTo(5));

    final batch = DemoData.importBatch(DateTime.now());
    expect(batch.items.length, 3);
    expect(batch.pendingCount, 3);
    // Staged payloads round-trip through the real parsers.
    for (final item in batch.items) {
      if (item.collection == 'nodes') {
        Node.fromJson(Map<String, dynamic>.from(item.data));
      } else {
        PlannerEvent.fromJson(Map<String, dynamic>.from(item.data));
      }
    }
    // One item is an update to an existing row, not a silent overwrite.
    expect(batch.items.any((i) => i.isUpdate), isTrue);
  });

  test('demo content is relative to today', () {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final nodes = DemoData.nodes(now);
    bool sameDay(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day;
    // Something due today, something overdue.
    expect(
      nodes.any((n) =>
          n.schedule?.due != null && sameDay(n.schedule!.due!, today)),
      isTrue,
    );
    expect(
      nodes.any((n) =>
          n.isOpen &&
          n.schedule?.due != null &&
          n.schedule!.due!.isBefore(today)),
      isTrue,
    );
  });
}
