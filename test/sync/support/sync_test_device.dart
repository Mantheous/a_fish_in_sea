import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/finances/service/plaid_service.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
import 'package:a_fish_in_sea/planner/service/canvas_service.dart';
import 'package:a_fish_in_sea/planner/service/ical_service.dart';
import 'package:a_fish_in_sea/reporting/bloc/places_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/tracking_cubit.dart';
import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:a_fish_in_sea/sync/sync_meta_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

class TestPlaidCubit extends PlaidCubit {
  TestPlaidCubit({PlaidService? service})
    : super(
        service:
            service ??
            PlaidService(
              baseUrl: 'https://plaid.test',
              userId: 'test-user',
              client: MockClient((_) async => http.Response('{}', 200)),
            ),
      );

  void seedConnected(String itemId) {
    emit(
      state.copyWith(status: PlaidConnectionStatus.connected, itemId: itemId),
    );
  }
}

class SyncRow {
  Map<String, dynamic> data;
  bool deleted;
  DateTime updatedAt;
  SyncRow(this.data, this.deleted, this.updatedAt);
}

/// In-memory stand-in for the FastAPI server (same pull/push semantics).
class FakeSyncClient extends SyncClient {
  FakeSyncClient()
    : super(
        serverBase: () => '',
        accessToken: () => 'tok',
        refreshAccessToken: () async => 'tok',
      );

  final store = <String, Map<String, SyncRow>>{};
  var pushCalls = 0;
  final pullCursors = <String?>[];
  var clock = DateTime.utc(2026, 9, 12);

  DateTime tick() {
    clock = clock.add(const Duration(seconds: 1));
    return clock;
  }

  @override
  Future<Map<String, dynamic>> login(String email, String password) async => {
    'access_token': 'a',
    'refresh_token': 'r',
  };

  @override
  Future<Map<String, dynamic>> register(String email, String password) async =>
      {'access_token': 'a', 'refresh_token': 'r'};

  @override
  Future<void> logout(String refreshToken) async {}

  @override
  Future<({List<SyncRecord> changes, String serverTime})> pull({
    String? since,
    List<String>? collections,
  }) async {
    pullCursors.add(since);
    final out = <SyncRecord>[];
    final sinceDt = since == null || since.isEmpty
        ? null
        : DateTime.parse(since);
    for (final coll in store.entries) {
      if (collections != null &&
          collections.isNotEmpty &&
          !collections.contains(coll.key)) {
        continue;
      }
      for (final e in coll.value.entries) {
        if (sinceDt != null && !e.value.updatedAt.isAfter(sinceDt)) continue;
        out.add(
          SyncRecord(
            collection: coll.key,
            itemId: e.key,
            data: Map<String, dynamic>.from(e.value.data),
            deleted: e.value.deleted,
            rev: 1,
            updatedAt: e.value.updatedAt,
          ),
        );
      }
    }
    out.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    return (changes: out, serverTime: clock.toIso8601String());
  }

  @override
  Future<({List<SyncRecord> applied, Set<String> guarded})> push(
    List<Map<String, dynamic>> changes,
  ) async {
    pushCalls++;
    final applied = <SyncRecord>[];
    for (final c in changes) {
      final coll = store.putIfAbsent(c['collection'] as String, () => {});
      final now = tick();
      coll[c['item_id'] as String] = SyncRow(
        Map<String, dynamic>.from(c['data'] as Map? ?? {}),
        c['deleted'] as bool? ?? false,
        now,
      );
      applied.add(
        SyncRecord(
          collection: c['collection'] as String,
          itemId: c['item_id'] as String,
          data: Map<String, dynamic>.from(c['data'] as Map? ?? {}),
          deleted: c['deleted'] as bool? ?? false,
          rev: 1,
          updatedAt: now,
        ),
      );
    }
    return (applied: applied, guarded: const <String>{});
  }
}

/// Simulates the real SyncClient's fail-closed behavior on an incomplete
/// paged pull (empty page with has_more, or a page without next_cursor):
/// it throws instead of returning a watermark, so the engine must not
/// advance its stored cursor (refs #57).
class IncompletePullClient extends FakeSyncClient {
  bool failPull = false;

  @override
  Future<({List<SyncRecord> changes, String serverTime})> pull({
    String? since,
    List<String>? collections,
  }) async {
    if (failPull) {
      throw const SyncException(
        500,
        'Sync server omitted the cursor for an incomplete pull',
      );
    }
    return super.pull(since: since, collections: collections);
  }
}

class SyncTestDevice {
  final FakeSyncClient server;
  late final AuthCubit auth;
  late final SyncMetaCubit meta;
  late final NodeCubit nodes;
  late final CalendarCubit events;
  late final FeedCubit feeds;
  late final SyncEngine engine;
  late final SettingsCubit settings;
  late final TestPlaidCubit plaid;
  late final WaterfallCubit waterfall;
  late final TransactionsCubit transactions;
  late final PlacesCubit places;
  late final ReportingCubit reporting;
  late final TrackingCubit tracking;

  SyncTestDevice(
    this.server, {
    IcalService? icalService,
    GoogleCalendarService? googleService,
    CanvasService? canvasService,
    PlaidService? plaidService,
  }) {
    auth = AuthCubit(client: () => server);
    meta = SyncMetaCubit();
    nodes = NodeCubit();
    events = CalendarCubit();
    feeds = FeedCubit(
      calendarCubit: events,
      nodeCubit: nodes,
      icalService: icalService ?? IcalService(),
      googleService:
          googleService ??
          GoogleCalendarService(baseUrl: () => '', userId: () => ''),
      canvasService: canvasService,
      proxyBase: () => '',
    );
    settings = SettingsCubit();
    transactions = TransactionsCubit();
    plaid = TestPlaidCubit(service: plaidService);
    places = PlacesCubit();
    reporting = ReportingCubit();
    tracking = TrackingCubit();
    waterfall = WaterfallCubit(
      nodeCubit: nodes,
      transactionsCubit: transactions,
      plaidCubit: plaid,
    );
    engine = SyncEngine(
      client: server,
      auth: auth,
      meta: meta,
      events: events,
      feeds: feeds,
      nodes: nodes,
      transactions: transactions,
      places: places,
      reporting: reporting,
      tracking: tracking,
      settings: settings,
      waterfall: waterfall,
      plaid: plaid,
    );
  }

  /// A fresh engine over the same cubits with [metaCubit] as bookkeeping —
  /// used to simulate an app restart without tearing down the UI state.
  SyncEngine engineOver(SyncMetaCubit metaCubit) => SyncEngine(
    client: server,
    auth: auth,
    meta: metaCubit,
    events: events,
    feeds: feeds,
    nodes: nodes,
    transactions: transactions,
    places: places,
    reporting: reporting,
    tracking: tracking,
    settings: settings,
    waterfall: waterfall,
    plaid: plaid,
  );

  SyncMetaCubit rehydratedMeta() {
    final fresh = SyncMetaCubit();
    fresh.emit(fresh.fromJson(meta.toJson(meta.state))!);
    return fresh;
  }

  Future<void> signIn() async {
    final ok = await auth.login('a@example.com', 'password123');
    assert(ok);
  }
}
