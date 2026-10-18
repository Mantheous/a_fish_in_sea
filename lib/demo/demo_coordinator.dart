// ignore_for_file: invalid_use_of_visible_for_testing_member, invalid_use_of_protected_member

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

import '../common/undo/undo_cubit.dart';
import '../finances/bloc/plaid_cubit.dart';
import '../finances/bloc/transactions_cubit.dart';
import '../finances/bloc/waterfall_cubit.dart';
import '../navigation/bloc/navigation_cubit.dart';
import '../nodes/bloc/node_cubit.dart';
import '../nodes/model/node.dart';
import '../planner/bloc/assignment_rules_cubit.dart';
import '../planner/bloc/assignment_estimates_cubit.dart';
import '../planner/bloc/calendar_cubit.dart';
import '../planner/bloc/calendar_visibility_cubit.dart';
import '../planner/bloc/feed_cubit.dart';
import '../planner/bloc/settings_cubit.dart';
import '../planner/bloc/tasks_view_options_cubit.dart';
import '../planner/model/assignment_rule.dart';
import '../planner/model/assignment_estimate.dart';
import '../planner/model/feed.dart';
import '../planner/model/planner_event.dart';
import '../reporting/bloc/places_cubit.dart';
import '../reporting/bloc/reporting_cubit.dart';
import '../reporting/bloc/tracking_cubit.dart';
import '../reporting/model/place.dart';
import '../reporting/model/reported_entry.dart';
import '../finances/model/transaction.dart';
import '../imports/import_service.dart';
import '../sync/sync_meta_cubit.dart';
import 'demo_cubit.dart';
import 'demo_data.dart';
import 'demo_mode.dart';
import 'demo_storage.dart';

/// Typed snapshot of every hydrated cubit, taken on demo entry and
/// re-emitted on exit. States are immutable, so holding the references is
/// a safe backup.
class _DemoSnapshot {
  final List<Feed> feeds;
  final List<PlannerEvent> events;
  final List<Node> nodes;
  final List<Transaction> transactions;
  final PlaidState plaid;
  final WaterfallState waterfall;
  final List<Place> places;
  final Map<String, List<ReportedEntry>> reporting;
  final TrackingState tracking;
  final SettingsState settings;
  final CalendarVisibilityState visibility;
  final TasksViewOptionsState viewOptions;
  final List<AssignmentRule> rules;
  final List<AssignmentTypeEffort> estimates;
  final SyncMetaState syncMeta;

  const _DemoSnapshot({
    required this.feeds,
    required this.events,
    required this.nodes,
    required this.transactions,
    required this.plaid,
    required this.waterfall,
    required this.places,
    required this.reporting,
    required this.tracking,
    required this.settings,
    required this.visibility,
    required this.viewOptions,
    required this.rules,
    required this.estimates,
    required this.syncMeta,
  });
}

/// Enters/exits demo mode.
///
/// Entry swaps [HydratedBloc.storage] for an ephemeral [DemoStorage] BEFORE
/// seeding, so mock data never reaches the on-disk box (a mid-demo kill
/// loses only the demo). In-memory states are snapshotted first and
/// restored on exit, so a signed-out device's kept local data survives a
/// demo tour untouched.
class DemoCoordinator {
  static Storage? _realStorage;
  static _DemoSnapshot? _snapshot;

  static bool get inDemo => _snapshot != null;

  static Future<void> enterDemo(BuildContext context) async {
    if (inDemo) return;
    final now = DateTime.now();

    // 1. Snapshot every hydrated cubit.
    _snapshot = _DemoSnapshot(
      feeds: context.read<FeedCubit>().state,
      events: context.read<CalendarCubit>().state,
      nodes: context.read<NodeCubit>().state,
      transactions: context.read<TransactionsCubit>().state,
      plaid: context.read<PlaidCubit>().state,
      waterfall: context.read<WaterfallCubit>().state,
      places: context.read<PlacesCubit>().state,
      reporting: context.read<ReportingCubit>().state,
      tracking: context.read<TrackingCubit>().state,
      settings: context.read<SettingsCubit>().state,
      visibility: context.read<CalendarVisibilityCubit>().state,
      viewOptions: context.read<TasksViewOptionsCubit>().state,
      rules: context.read<AssignmentRulesCubit>().state,
      estimates: context.read<AssignmentEstimatesCubit>().state,
      syncMeta: context.read<SyncMetaCubit>().state,
    );

    // 2. Redirect persistence to ephemeral memory.
    _realStorage = HydratedBloc.storage;
    HydratedBloc.storage = DemoStorage();
    DemoMocks.reset();
    DemoMode.isActive = true;
    context.read<DemoCubit>().entered();

    // 3. Seed mock content (silent paths — no undo records).
    final feeds = DemoData.feeds(now);
    context.read<FeedCubit>().applyJson({
      'feeds': feeds.map((f) => f.toJson()).toList(),
    });
    final calendar = context.read<CalendarCubit>();
    final feedEvents = DemoData.feedEvents(now);
    final allEvents = [
      for (final feed in feeds)
        ...feedEvents.where((e) => e.feedId == feed.id),
      ...DemoData.personalEvents(now),
    ];
    calendar.applyJson({
      'events': allEvents.map((e) => e.toJson()).toList(),
    });
    context.read<NodeCubit>().emitSilent(DemoData.nodes(now));
    context.read<TransactionsCubit>().applySyncedJson({
      'transactions':
          DemoData.transactions(now).map((t) => t.toJson()).toList(),
    });
    context.read<PlaidCubit>().emit(PlaidState(
          userId: 'demo-user',
          status: PlaidConnectionStatus.connected,
          itemId: 'demo-item',
          currentBalance: 10440.12,
          accounts: DemoData.plaidAccounts(),
        ));
    context.read<PlacesCubit>().applyJson({
      'places': DemoData.places().map((p) => p.toJson()).toList(),
    });
    final reported = DemoData.reportedEntries(now);
    context.read<ReportingCubit>().applyJson({
      'days': {
        for (final e in reported.entries)
          e.key: e.value.map((r) => r.toJson()).toList(),
      },
    });
    context.read<TrackingCubit>().emit(
          TrackingState(points: DemoData.trackedPoints(now)),
        );

    UndoCubit.instance?.resetHistory();
    context.read<NavigationCubit>().setPage(PlannerPage.home);
    // The waterfall rebuilds itself off the seeded sources (debounced);
    // nudge it once so Finances is populated on first open.
    context.read<WaterfallCubit>().rebuild();
  }

  static Future<void> exitDemo(BuildContext context) async {
    final snapshot = _snapshot;
    final real = _realStorage;
    if (snapshot == null || real == null) return;

    DemoMode.isActive = false;
    try {
      context.read<DemoCubit>().exited();
    } catch (_) {}

    // Point persistence back at the real box BEFORE re-emitting, so the
    // restored states land where they belong (same values — harmless).
    HydratedBloc.storage = real;
    _realStorage = null;
    _snapshot = null;
    DemoMocks.reset();

    context.read<FeedCubit>().applyJson({
      'feeds': snapshot.feeds.map((f) => f.toJson()).toList(),
    });
    context.read<CalendarCubit>().applyJson({
      'events': snapshot.events.map((e) => e.toJson()).toList(),
    });
    context.read<NodeCubit>().emitSilent(snapshot.nodes);
    context.read<TransactionsCubit>().applySyncedJson({
      'transactions': snapshot.transactions.map((t) => t.toJson()).toList(),
    });
    context.read<PlaidCubit>().emit(snapshot.plaid);
    context.read<PlacesCubit>().applyJson({
      'places': snapshot.places.map((p) => p.toJson()).toList(),
    });
    context.read<ReportingCubit>().applyJson({
      'days': {
        for (final e in snapshot.reporting.entries)
          e.key: e.value.map((r) => r.toJson()).toList(),
      },
    });
    context.read<TrackingCubit>().emit(snapshot.tracking);
    // Full replace (not applySyncedJson, which would keep a demo-edited
    // server URL): the snapshot is this device's own state.
    context.read<SettingsCubit>().emit(snapshot.settings);
    context.read<CalendarVisibilityCubit>().emit(snapshot.visibility);
    context.read<TasksViewOptionsCubit>().emit(snapshot.viewOptions);
    context.read<AssignmentRulesCubit>().emit(snapshot.rules);
    context.read<AssignmentEstimatesCubit>().emit(snapshot.estimates);
    context.read<SyncMetaCubit>().emit(snapshot.syncMeta);
    context.read<WaterfallCubit>().emit(snapshot.waterfall);

    UndoCubit.instance?.resetHistory();
    try {
      context.read<NavigationCubit>().setPage(PlannerPage.home);
    } catch (_) {}
    context.read<WaterfallCubit>().rebuild();
  }

  // ── Demo import inbox ──────────────────────────────────────────────
  //
  // The server approve/discard/reject endpoints don't exist without a
  // session, so demo decisions apply staged payloads straight to the
  // local cubits (same fromJson parsers the sync path uses).

  static List<ImportBatch> demoPendingImports() {
    if (!DemoMode.isActive) return const [];
    final batch = DemoData.importBatch(DateTime.now());
    return batch.pendingCount == 0 ? const [] : [batch];
  }

  static Future<ImportBatch> demoApprove(
    BuildContext context,
    int batchId, {
    List<String>? itemIds,
  }) async {
    final batch = DemoData.importBatch(DateTime.now());
    final byId = {for (final i in batch.items) i.itemId: i};
    final ids = itemIds ?? [for (final i in batch.pending) i.itemId];
    final nodes = context.read<NodeCubit>();
    final calendar = context.read<CalendarCubit>();
    for (final id in ids) {
      final item = byId[id];
      if (item == null || !item.isPending) continue;
      DemoMocks.importDecisions[id] = 'approved';
      _applyStagedItem(nodes, calendar, item);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return DemoData.importBatch(DateTime.now());
  }

  static Future<ImportBatch> demoDiscard(
    BuildContext context,
    int batchId,
    List<String> itemIds,
  ) async {
    for (final id in itemIds) {
      DemoMocks.importDecisions[id] = 'discarded';
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return DemoData.importBatch(DateTime.now());
  }

  static Future<ImportBatch> demoReject(
    BuildContext context,
    int batchId,
  ) async {
    final batch = DemoData.importBatch(DateTime.now());
    for (final item in batch.pending) {
      DemoMocks.importDecisions[item.itemId] = 'discarded';
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return DemoData.importBatch(DateTime.now());
  }

  static void _applyStagedItem(
    NodeCubit nodes,
    CalendarCubit calendar,
    StagedItem item,
  ) {
    try {
      if (item.collection == 'nodes') {
        final node = Node.fromJson(Map<String, dynamic>.from(item.data));
        nodes.emitSilent([
          ...nodes.state.where((n) => n.id != node.id),
          node,
        ]);
      } else if (item.collection == 'events') {
        final event =
            PlannerEvent.fromJson(Map<String, dynamic>.from(item.data));
        final list = [
          ...calendar.state.where((e) => e.id != event.id),
          event,
        ];
        calendar.applyJson({
          'events': [for (final e in list) e.toJson()],
        });
      }
    } catch (_) {}
  }
}
