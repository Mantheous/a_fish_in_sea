import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/feed_cubit.dart';
import 'package:a_fish_in_sea/planner/bloc/settings_cubit.dart';
import 'package:a_fish_in_sea/planner/service/google_calendar_service.dart';
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
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

class _Row {
  Map<String, dynamic> data;
  bool deleted;
  DateTime updatedAt;
  _Row(this.data, this.deleted, this.updatedAt);
}

/// In-memory stand-in for the FastAPI server (same pull/push semantics).
class FakeSyncClient extends SyncClient {
  FakeSyncClient()
      : super(
          serverBase: () => '',
          accessToken: () => 'tok',
          refreshAccessToken: () async => 'tok',
        );

  final store = <String, Map<String, _Row>>{};
  var clock = DateTime.utc(2026, 9, 12);

  DateTime _tick() {
    clock = clock.add(const Duration(seconds: 1));
    return clock;
  }

  @override
  Future<Map<String, dynamic>> login(String email, String password) async =>
      {'access_token': 'a', 'refresh_token': 'r'};

  @override
  Future<Map<String, dynamic>> register(String email, String password) async =>
      {'access_token': 'a', 'refresh_token': 'r'};

  @override
  Future<({List<SyncRecord> changes, String serverTime})> pull({
    String? since,
    List<String>? collections,
  }) async {
    final out = <SyncRecord>[];
    final sinceDt =
        since == null || since.isEmpty ? null : DateTime.parse(since);
    for (final coll in store.entries) {
      if (collections != null &&
          collections.isNotEmpty &&
          !collections.contains(coll.key)) {
        continue;
      }
      for (final e in coll.value.entries) {
        if (sinceDt != null && !e.value.updatedAt.isAfter(sinceDt)) continue;
        out.add(SyncRecord(
          collection: coll.key,
          itemId: e.key,
          data: Map<String, dynamic>.from(e.value.data),
          deleted: e.value.deleted,
          rev: 1,
          updatedAt: e.value.updatedAt,
        ));
      }
    }
    out.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    return (changes: out, serverTime: clock.toIso8601String());
  }

  @override
  Future<({List<SyncRecord> applied, Set<String> guarded})> push(
      List<Map<String, dynamic>> changes) async {
    final applied = <SyncRecord>[];
    for (final c in changes) {
      final coll =
          store.putIfAbsent(c['collection'] as String, () => {});
      final now = _tick();
      coll[c['item_id'] as String] = _Row(
        Map<String, dynamic>.from(c['data'] as Map? ?? {}),
        c['deleted'] as bool? ?? false,
        now,
      );
      applied.add(SyncRecord(
        collection: c['collection'] as String,
        itemId: c['item_id'] as String,
        data: Map<String, dynamic>.from(c['data'] as Map? ?? {}),
        deleted: c['deleted'] as bool? ?? false,
        rev: 1,
        updatedAt: now,
      ));
    }
    return (applied: applied, guarded: const <String>{});
  }
}

class _Device {
  final FakeSyncClient server;
  late final AuthCubit auth;
  late final SyncMetaCubit meta;
  late final NodeCubit nodes;
  late final CalendarCubit events;
  late final FeedCubit feeds;
  late final SyncEngine engine;
  late final SettingsCubit settings;

  _Device(this.server) {
    auth = AuthCubit(client: () => server);
    meta = SyncMetaCubit();
    nodes = NodeCubit();
    events = CalendarCubit();
    feeds = FeedCubit(
      calendarCubit: events,
      nodeCubit: nodes,
      icalService: IcalService(),
      googleService: GoogleCalendarService(baseUrl: () => '', userId: () => ''),
      proxyBase: () => '',
    );
    settings = SettingsCubit();
    final transactions = TransactionsCubit();
    final plaid = PlaidCubit();
    final places = PlacesCubit();
    final reporting = ReportingCubit();
    final tracking = TrackingCubit();
    final waterfall = WaterfallCubit(
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

  Future<void> signIn() async {
    final ok = await auth.login('a@example.com', 'password123');
    assert(ok);
  }
}

void main() {
  late Storage storage;

  setUp(() {
    storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  test('node created on device A appears on device B after sync', () async {
    final server = FakeSyncClient();
    final a = _Device(server);
    final b = _Device(server);
    await a.signIn();
    await b.signIn();

    a.nodes.addNode(Node(
        id: 't1', title: 'Buy milk', createdAt: DateTime(2026)));
    await a.engine.syncNow();
    expect(a.engine.status.value, EngineStatus.idle);

    await b.engine.syncNow();
    expect(b.nodes.byId('t1')?.title, 'Buy milk');
  });

  test('true conflict resolves server-wins', () async {
    final server = FakeSyncClient();
    final a = _Device(server);
    final b = _Device(server);
    await a.signIn();
    await b.signIn();

    a.nodes.addNode(Node(id: 't1', title: 'v1', createdAt: DateTime(2026)));
    await a.engine.syncNow();
    await b.engine.syncNow(); // B baselines on v1

    b.nodes.updateNode(b.nodes.byId('t1')!.copyWith(title: 'B edit'));
    await b.engine.syncNow(); // server is now 'B edit'

    a.nodes.updateNode(a.nodes.byId('t1')!.copyWith(title: 'A edit'));
    await a.engine.syncNow(); // conflict -> server wins

    expect(a.nodes.byId('t1')?.title, 'B edit');
  });

  test('delete on A propagates as tombstone to B', () async {
    final server = FakeSyncClient();
    final a = _Device(server);
    final b = _Device(server);
    await a.signIn();
    await b.signIn();

    a.nodes.addNode(Node(id: 't1', title: 'temp', createdAt: DateTime(2026)));
    await a.engine.syncNow();
    await b.engine.syncNow();
    expect(b.nodes.byId('t1'), isNotNull);

    a.nodes.deleteNode('t1');
    await a.engine.syncNow();
    await b.engine.syncNow();
    expect(b.nodes.byId('t1'), isNull);
  });

  test('mass deletion from a wiped device is withheld, not propagated',
      () async {
    final server = FakeSyncClient();
    final a = _Device(server);
    final b = _Device(server);
    await a.signIn();
    await b.signIn();

    for (var i = 0; i < 6; i++) {
      a.nodes.addNode(
          Node(id: 't$i', title: 'n$i', createdAt: DateTime(2026)));
    }
    await a.engine.syncNow();
    await b.engine.syncNow();
    expect(b.nodes.state.length, 6);

    // Simulate local storage loss on A: the cubit empties while the sync
    // bookkeeping survives (applyJson emits state without touching meta).
    a.nodes.applyJson({'nodes': const []});
    expect(a.nodes.state, isEmpty);

    await a.engine.syncNow();

    // The guard held the tombstones; the server and B keep the data.
    expect(a.engine.protectedDeletions.value, ['nodes']);
    await b.engine.syncNow();
    expect(b.nodes.state.length, 6);
    expect(server.store['nodes']?.length, 6);
  });

  test('settings server URL stays per-device', () async {
    final server = FakeSyncClient();
    final a = _Device(server);
    await a.signIn();

    a.settings.setIcalProxyBase('http://phone:8000');
    await a.engine.syncNow();
    await a.engine.syncNow();
    expect(a.settings.state.icalProxyBase, 'http://phone:8000');

    final pushed =
        server.store['settings']?['singleton']?.data ?? const {};
    expect(pushed.containsKey('icalProxyBase'), isFalse);
  });

  test('a running timer survives a conflicting pull (server-wins except timers)',
      () async {
    final server = FakeSyncClient();
    final a = _Device(server);
    final b = _Device(server);
    await a.signIn();
    await b.signIn();

    a.nodes.addNode(Node(id: 't1', title: 'v1', createdAt: DateTime(2026)));
    await a.engine.syncNow();
    await b.engine.syncNow(); // B baselines on v1

    // A starts a timer but has not pushed yet (e.g. rebuilt before sync).
    final t0 = DateTime(2026, 9, 12, 9);
    a.nodes.startTracking('t1', now: t0);

    // B renames the node and syncs: the server copy advances without the
    // timer, so A's next pull is a true conflict.
    b.nodes.updateNode(b.nodes.byId('t1')!.copyWith(title: 'B edit'));
    await b.engine.syncNow();

    await a.engine.syncNow();

    // The rename lands (server wins), but the live timer is not stopped.
    final live = a.nodes.byId('t1')!;
    expect(live.title, 'B edit');
    expect(live.isTracking, isTrue);
    expect(live.timerStartedAt, t0);
  });

  test('conflicting running timers keep the earliest start', () async {
    final server = FakeSyncClient();
    final a = _Device(server);
    final b = _Device(server);
    await a.signIn();
    await b.signIn();

    a.nodes.addNode(Node(id: 't1', title: 'v1', createdAt: DateTime(2026)));
    await a.engine.syncNow();
    await b.engine.syncNow(); // B baselines on v1

    // A starts at 9:00 and pushes; B started earlier at 8:30 offline.
    a.nodes.startTracking('t1', now: DateTime(2026, 9, 12, 9));
    await a.engine.syncNow();
    b.nodes.startTracking('t1', now: DateTime(2026, 9, 12, 8, 30));
    await b.engine.syncNow();

    // The true (earliest) start wins on both sides.
    expect(b.nodes.byId('t1')?.timerStartedAt, DateTime(2026, 9, 12, 8, 30));
    await a.engine.syncNow();
    expect(a.nodes.byId('t1')?.timerStartedAt, DateTime(2026, 9, 12, 8, 30));
  });

  test('remote edit propagates to a device with no local changes', () async {
    final server = FakeSyncClient();
    final a = _Device(server);
    final b = _Device(server);
    await a.signIn();
    await b.signIn();

    a.nodes.addNode(Node(id: 't1', title: 'v1', createdAt: DateTime(2026)));
    await a.engine.syncNow();
    await b.engine.syncNow();

    b.nodes.updateNode(b.nodes.byId('t1')!.copyWith(title: 'B edit'));
    await b.engine.syncNow();

    // A never touched the node: the remote rename must land.
    await a.engine.syncNow();
    expect(a.nodes.byId('t1')?.title, 'B edit');
  });

  test('a remote stop lands even under a conflicting local edit', () async {
    final server = FakeSyncClient();
    final a = _Device(server);
    final b = _Device(server);
    await a.signIn();
    await b.signIn();

    a.nodes.addNode(Node(id: 't1', title: 'v1', createdAt: DateTime(2026)));
    await a.engine.syncNow();
    await b.engine.syncNow();

    // The run roams to B, B stops it, and the stop reaches the server.
    a.nodes.startTracking('t1', now: DateTime(2026, 9, 12, 9));
    await a.engine.syncNow();
    await b.engine.syncNow();
    b.nodes.stopTracking('t1', now: DateTime(2026, 9, 12, 9, 30));
    await b.engine.syncNow();

    // A renames mid-run (local change), then pulls the stop: conflict,
    // server wins the title, and the stop — which ended after A's start
    // — clears the local timer instead of resurrecting it.
    a.nodes.updateNode(a.nodes.byId('t1')!.copyWith(title: 'A edit'));
    await a.engine.syncNow();

    final live = a.nodes.byId('t1')!;
    expect(live.title, 'v1');
    expect(live.isTracking, isFalse);
    expect(live.actualStart, DateTime(2026, 9, 12, 9));
    expect(live.actualEnd, DateTime(2026, 9, 12, 9, 30));
  });

  test('old remote actuals never stop a restarted timer', () async {
    final server = FakeSyncClient();
    final a = _Device(server);
    final b = _Device(server);
    await a.signIn();
    await b.signIn();

    a.nodes.addNode(Node(id: 't1', title: 'v1', createdAt: DateTime(2026)));
    await a.engine.syncNow();
    await b.engine.syncNow();

    // Session one runs and stops on B; A adopts the stop cleanly.
    b.nodes.startTracking('t1', now: DateTime(2026, 9, 12, 8, 30));
    await b.engine.syncNow();
    await a.engine.syncNow();
    b.nodes.stopTracking('t1', now: DateTime(2026, 9, 12, 9, 30));
    await b.engine.syncNow();
    await a.engine.syncNow();
    expect(a.nodes.byId('t1')?.hasReported, isTrue);

    // Session two starts on A; B renames and syncs. A's conflicting pull
    // meets a server copy whose actuals predate the new run — the live
    // timer survives while the rename still lands.
    final t0 = DateTime(2026, 9, 12, 10);
    a.nodes.startTracking('t1', now: t0);
    b.nodes.updateNode(b.nodes.byId('t1')!.copyWith(title: 'B edit'));
    await b.engine.syncNow();
    await a.engine.syncNow();

    final live = a.nodes.byId('t1')!;
    expect(live.title, 'B edit');
    expect(live.isTracking, isTrue);
    expect(live.timerStartedAt, t0);
  });

  test('contentHash is stable and sensitive', () {
    expect(
      contentHash(const {'a': 1}),
      contentHash(const {'a': 1}),
    );
    expect(contentHash(const {'a': 1}), isNot(contentHash(const {'a': 2})));
  });

  test('switching accounts or signing out never leaks previous user data into next account',
      () async {
    final server = FakeSyncClient();
    final shared = _Device(server);

    await shared.auth.login('alice@example.com', 'password123');
    shared.nodes.addNode(
      Node(id: 'alice-secret', title: 'Alice secret task', createdAt: DateTime(2026)),
    );
    await shared.engine.syncNow();
    expect(server.store['nodes']?.containsKey('alice-secret'), isTrue);

    // Case 2: Alice also adds an UNSYNCED offline item before signing out, then
    // the app restarts (fresh SyncEngine constructed from persisted SyncMetaCubit)
    // and Bob signs in. Zero of Alice's items leak to Bob's cloud, AND Alice's
    // unsynced item is preserved in SyncMetaCubit.accountSnapshots across the
    // restart so it comes back when Alice signs back in.
    shared.nodes.addNode(
      Node(id: 'alice-unsynced', title: 'Offline draft', createdAt: DateTime(2026)),
    );
    shared.engine.signOut();
    expect(shared.nodes.byId('alice-unsynced'), isNotNull);
    expect(shared.meta.state.items, isEmpty);
    expect(shared.meta.state.lastEmail, 'alice@example.com');

    // Simulate app restart: re-hydrate SyncMetaCubit from JSON and build a
    // fresh SyncEngine over the existing cubits.
    final rehydratedMeta = SyncMetaCubit();
    rehydratedMeta.emit(
      rehydratedMeta.fromJson(shared.meta.toJson(shared.meta.state))!,
    );
    final restartedEngine = SyncEngine(
      client: server,
      auth: shared.auth,
      meta: rehydratedMeta,
      events: shared.events,
      feeds: shared.feeds,
      nodes: shared.nodes,
      transactions: TransactionsCubit(),
      places: PlacesCubit(),
      reporting: ReportingCubit(),
      tracking: TrackingCubit(),
      settings: shared.settings,
      waterfall: WaterfallCubit(
        nodeCubit: shared.nodes,
        transactionsCubit: TransactionsCubit(),
        plaidCubit: PlaidCubit(),
      ),
      plaid: PlaidCubit(),
    );

    // Simulate Bob's empty cloud account on the server.
    server.store.clear();

    await shared.auth.login('bob@example.com', 'password123');
    rehydratedMeta.reset(); // AuthPage resets cursor/items, preserving lastEmail
    await restartedEngine.syncNow();

    expect(shared.nodes.byId('alice-secret'), isNull);
    expect(shared.nodes.byId('alice-unsynced'), isNull);
    expect(server.store['nodes']?.containsKey('alice-secret') ?? false, isFalse);
    expect(server.store['nodes']?.containsKey('alice-unsynced') ?? false, isFalse);

    // When Alice signs back in later, her unsynced offline item is restored
    // from the persisted snapshot!
    await shared.auth.login('alice@example.com', 'password123');
    rehydratedMeta.reset();
    await restartedEngine.syncNow();
    expect(shared.nodes.byId('alice-unsynced')?.title, 'Offline draft');
  });

  test('signOut mid-sync fences in-flight sync so meta stays reset', () async {
    final server = FakeSyncClient();
    final d = _Device(server);
    await d.signIn();
    d.nodes.addNode(Node(id: 't1', title: 'v1', createdAt: DateTime(2026)));

    final syncFuture = d.engine.syncNow();
    d.engine.signOut();
    await syncFuture;

    expect(d.auth.state.isSignedIn, isFalse);
    expect(d.meta.state.cursor, isNull);
    expect(d.meta.state.items, isEmpty);
    // Local data stays intact on sign-out.
    expect(d.nodes.byId('t1')?.title, 'v1');
  });
}
