import 'dart:convert';

import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/demo/demo_coordinator.dart';
import 'package:a_fish_in_sea/demo/demo_data.dart';
import 'package:a_fish_in_sea/demo/demo_mode.dart';
import 'package:a_fish_in_sea/demo/demo_storage.dart';
import 'package:a_fish_in_sea/feedback/feedback_service.dart';
import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/finances/model/transaction.dart';
import 'package:a_fish_in_sea/navigation/bloc/navigation_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/assignment_estimates_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/assignment_rules_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_visibility_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/tasks_view_options_cubit.dart';
import 'package:a_fish_in_sea/planner/model/assignment_estimate.dart';
import 'package:a_fish_in_sea/planner/model/feed.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/reporting/bloc/places_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/tracking_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_meta_cubit.dart';
import 'package:a_fish_in_sea/demo/demo_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

/// In-memory [Storage] so the demo tour test never touches disk.
class _MemoryStorage implements Storage {
  final _map = <String, dynamic>{};

  @override
  dynamic read(String key) => _map[key];

  @override
  Future<void> write(String key, dynamic value) async {
    _map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _map.remove(key);
  }

  @override
  Future<void> clear() async {
    _map.clear();
  }

  @override
  Future<void> close() async {}
}

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

  test('demo feedback reports are seeded read-only content', () {
    final now = DateTime.now();
    final reports = DemoData.demoReports(now);
    expect(reports.length, 2);
    expect(reports.every((r) => r.email == DemoMode.demoEmail), isTrue);
    expect(reports.any((r) => r.kind == 'bug' && r.status == 'filed'), isTrue);
    expect(
      reports.any((r) => r.kind == 'feature' && r.status == 'pending'),
      isTrue,
    );
    // Each report parses back through the real fromJson.
    for (final report in reports) {
      final parsed = FeedbackReport.fromJson({
        'id': report.id,
        'kind': report.kind,
        'title': report.title,
        'description': report.description,
        'device': report.device,
        'extra': report.extra,
        'status': report.status,
        'email': report.email,
      });
      expect(parsed.id, report.id);
      expect(parsed.status, report.status);
    }
  });

  test('demoFeedback is empty outside demo mode and seeded inside it', () {
    expect(DemoMode.isActive, isFalse);
    final outside = DemoCoordinator.demoFeedback();
    expect(outside.status.isAdmin, isFalse);
    expect(outside.mine, isEmpty);
    expect(outside.pending, isEmpty);
    expect(outside.trusted, isEmpty);

    DemoMode.isActive = true;
    try {
      final inside = DemoCoordinator.demoFeedback();
      expect(inside.status.isAdmin, isFalse);
      expect(inside.mine, hasLength(2));
      expect(inside.pending, isEmpty);
      expect(inside.trusted, isEmpty);
    } finally {
      DemoMode.isActive = false;
    }
    expect(DemoMode.isActive, isFalse);
  });

  testWidgets(
      'exiting demo restores the real balance and learned estimates byte-identical',
      (tester) async {
    // Each test file runs in its own isolate and no earlier test in this
    // file touches HydratedBloc, so installing a fresh in-memory box here
    // (and leaving it) is safe; it never reaches disk.
    HydratedBloc.storage = _MemoryStorage();
    addTearDown(() {
      DemoMode.isActive = false;
    });

    UndoCubit();
    final nodes = NodeCubit();
    final transactions = TransactionsCubit();
    final plaid = PlaidCubit();
    final waterfall = WaterfallCubit(
      nodeCubit: nodes,
      transactionsCubit: transactions,
      plaidCubit: plaid,
    );
    final calendar = CalendarCubit();
    final feeds = FeedCubit(
      calendarCubit: calendar,
      nodeCubit: nodes,
      icalService: IcalService(),
      googleService: GoogleCalendarService(
        baseUrl: () => '',
        userId: () => 'test-user',
      ),
      proxyBase: () => '',
    );
    final places = PlacesCubit();
    final reporting = ReportingCubit();
    final tracking = TrackingCubit();
    final settings = SettingsCubit();
    final visibility = CalendarVisibilityCubit();
    final viewOptions = TasksViewOptionsCubit();
    final rules = AssignmentRulesCubit();
    final estimates = AssignmentEstimatesCubit();
    final meta = SyncMetaCubit();
    final demo = DemoCubit();
    final navigation = NavigationCubit();
    addTearDown(() async {
      await demo.close();
      await navigation.close();
      await meta.close();
      await estimates.close();
      await rules.close();
      await viewOptions.close();
      await visibility.close();
      await settings.close();
      await tracking.close();
      await reporting.close();
      await places.close();
      await feeds.close();
      await calendar.close();
      await waterfall.close();
      await plaid.close();
      await transactions.close();
      await nodes.close();
      await UndoCubit.instance?.close();
    });

    late BuildContext ctx;
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider.value(value: UndoCubit.instance!),
          BlocProvider.value(value: demo),
          BlocProvider.value(value: navigation),
          BlocProvider.value(value: settings),
          BlocProvider.value(value: meta),
          BlocProvider.value(value: nodes),
          BlocProvider.value(value: transactions),
          BlocProvider.value(value: plaid),
          BlocProvider.value(value: waterfall),
          BlocProvider.value(value: calendar),
          BlocProvider.value(value: visibility),
          BlocProvider.value(value: viewOptions),
          BlocProvider.value(value: rules),
          BlocProvider.value(value: estimates),
          BlocProvider.value(value: places),
          BlocProvider.value(value: tracking),
          BlocProvider.value(value: reporting),
          BlocProvider.value(value: feeds),
        ],
        child: Builder(
          builder: (c) {
            ctx = c;
            return const MaterialApp(home: Scaffold(body: SizedBox()));
          },
        ),
      ),
    );

    // Seed real user data: a bank balance, one real class, learned time
    // estimates for it.
    plaid.emit(const PlaidState(
      userId: 'real-user',
      status: PlaidConnectionStatus.connected,
      itemId: 'real-item',
      currentBalance: 1234.56,
    ));
    estimates.emit([
      AssignmentTypeEffort(
        feedId: 'real-feed',
        templateKey: 'quiz',
        classLabel: 'Real Class',
        displayName: 'Quiz',
        samples: 3,
        totalMinutes: 90,
        minutes: const [30],
        startMinutes: const [1140],
        minMinutes: 30,
        maxMinutes: 30,
        updatedAt: DateTime(2026, 1, 1),
      ),
    ]);
    feeds.addFeed(const Feed(
      id: 'real-feed',
      name: 'Real Class',
      url: 'https://example.com/real.ics',
    ));
    // Flush the waterfall's Plaid subscription so the seeded balance lands
    // before the pre-demo snapshot is taken.
    await tester.pumpAndSettle();
    expect(waterfall.state.startingBalance, 1234.56);

    String snapOf(dynamic cubit) =>
        jsonEncode(cubit.toJson(cubit.state));
    Map<String, String> snapshotAll() => {
          'feeds': snapOf(feeds),
          'events': snapOf(calendar),
          'nodes': snapOf(nodes),
          'transactions': snapOf(transactions),
          'plaid': snapOf(plaid),
          'waterfall': snapOf(waterfall),
          'places': snapOf(places),
          'reporting': snapOf(reporting),
          'tracking': snapOf(tracking),
          'settings': snapOf(settings),
          'visibility': snapOf(visibility),
          'viewOptions': snapOf(viewOptions),
          'rules': snapOf(rules),
          'estimates': snapOf(estimates),
          'syncMeta': snapOf(meta),
        };
    final before = snapshotAll();

    await DemoCoordinator.enterDemo(ctx);
    await tester.pumpAndSettle();
    expect(DemoMode.isActive, isTrue);
    // The mock bank balance lands in demo (proves the tour ran).
    expect(waterfall.state.startingBalance, 10440.12);

    await DemoCoordinator.exitDemo(ctx);
    await tester.pumpAndSettle();
    expect(DemoMode.isActive, isFalse);
    expect(waterfall.state.startingBalance, 1234.56);
    expect(
      estimates.state.map((e) => e.feedId),
      ['real-feed'],
      reason: 'learned estimates for real classes survive the tour',
    );
    expect(
      snapshotAll(),
      before,
      reason: 'every snapshotted cubit restores byte-identical',
    );
  });
}
