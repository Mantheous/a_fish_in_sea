import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/finances/service/plaid_service.dart';
import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
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
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

class MockStorage extends Mock implements Storage {}

class _TestPlaidCubit extends PlaidCubit {
  _TestPlaidCubit()
    : super(
        service: PlaidService(
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
  var pushCalls = 0;
  var clock = DateTime.utc(2026, 9, 12);

  DateTime _tick() {
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
  Future<({List<SyncRecord> changes, String serverTime})> pull({
    String? since,
    List<String>? collections,
  }) async {
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
      final now = _tick();
      coll[c['item_id'] as String] = _Row(
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
class _IncompletePullClient extends FakeSyncClient {
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

class _Device {
  final FakeSyncClient server;
  late final AuthCubit auth;
  late final SyncMetaCubit meta;
  late final NodeCubit nodes;
  late final CalendarCubit events;
  late final FeedCubit feeds;
  late final SyncEngine engine;
  late final SettingsCubit settings;
  late final _TestPlaidCubit plaid;
  late final WaterfallCubit waterfall;

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
    plaid = _TestPlaidCubit();
    final places = PlacesCubit();
    final reporting = ReportingCubit();
    final tracking = TrackingCubit();
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

    a.nodes.addNode(
      Node(id: 't1', title: 'Buy milk', createdAt: DateTime(2026)),
    );
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

  test(
    'undo after a pull keeps pulled items and pushes no tombstone',
    () async {
      final undo = UndoCubit();
      addTearDown(undo.close);
      final server = FakeSyncClient();
      final a = _Device(server);
      await a.signIn();

      a.nodes.addNode(
        Node(id: 't1', title: 'original', createdAt: DateTime(2026)),
      );
      await a.engine.syncNow();
      a.nodes.updateNode(a.nodes.byId('t1')!.copyWith(title: 'edited'));
      expect(undo.canUndo, isTrue);

      // Another device creates t2 directly on the server (newer than a's
      // cursor, so the next pull delivers it like a background sync would).
      server.store.putIfAbsent('nodes', () => {})['t2'] = _Row(
        Node(id: 't2', title: 'from B', createdAt: DateTime(2026)).toJson(),
        false,
        server._tick(),
      );
      await a.engine.syncNow();

      expect(a.nodes.byId('t2')?.title, 'from B');
      // Item-scoped undo survives the pull: the edit reverts, the pulled
      // item stays, and history is preserved.
      expect(undo.canUndo, isTrue);
      undo.undo();
      expect(a.nodes.byId('t1')?.title, 'original');
      expect(a.nodes.byId('t2')?.title, 'from B');

      // The next push must not tombstone the pulled item.
      await a.engine.syncNow();
      expect(server.store['nodes']?['t2']?.deleted, isFalse);
      expect(a.engine.protectedDeletions.value, isEmpty);
      expect(a.nodes.byId('t2')?.title, 'from B');
    },
  );

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

  test(
    'mass deletion from a wiped device is withheld, not propagated',
    () async {
      final server = FakeSyncClient();
      final a = _Device(server);
      final b = _Device(server);
      await a.signIn();
      await b.signIn();

      for (var i = 0; i < 6; i++) {
        a.nodes.addNode(
          Node(id: 't$i', title: 'n$i', createdAt: DateTime(2026)),
        );
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
    },
  );

  test('settings server URL stays per-device', () async {
    final server = FakeSyncClient();
    final a = _Device(server);
    await a.signIn();

    a.settings.setIcalProxyBase('http://phone:8000');
    await a.engine.syncNow();
    await a.engine.syncNow();
    expect(a.settings.state.icalProxyBase, 'http://phone:8000');

    final pushed = server.store['settings']?['singleton']?.data ?? const {};
    expect(pushed.containsKey('icalProxyBase'), isFalse);
  });

  test(
    'settings and Plaid singletons do not ping-pong between devices',
    () async {
      final server = FakeSyncClient();
      final a = _Device(server);
      final b = _Device(server);
      await a.signIn();
      await b.signIn();

      a.settings.setAnkiConnectHost('http://desktop:8765');
      b.settings.setAnkiConnectHost('http://phone-lan:8765');
      a.plaid.seedConnected('item-1');

      await a.engine.syncNow();
      expect(
        server.store['settings']?['singleton']?.data['ankiConnectHost'],
        isNull,
      );
      expect(server.store['plaid']?['singleton']?.data, {
        'userId': a.plaid.state.userId,
        'itemId': 'item-1',
      });

      await b.engine.syncNow();
      expect(b.settings.state.ankiConnectHost, 'http://phone-lan:8765');
      expect(a.settings.state.ankiConnectHost, 'http://desktop:8765');
      expect(b.plaid.state.itemId, 'item-1');
      expect(b.plaid.state.isConnected, isFalse);

      // A disconnected device must not overwrite the active identity or push
      // its per-device host when its next sync sees no remote changes.
      final pushesBeforeNoopSync = server.pushCalls;
      await b.engine.syncNow();
      expect(server.pushCalls, pushesBeforeNoopSync);
      expect(
        server.store['settings']?['singleton']?.data['ankiConnectHost'],
        isNull,
      );
      expect(server.store['plaid']?['singleton']?.data['itemId'], 'item-1');

      // An explicit disconnect is represented by itemId:null and must clear
      // the identity on the other device without a false-status echo.
      await a.plaid.disconnect();
      await a.engine.syncNow();
      expect(server.store['plaid']?['singleton']?.data['itemId'], isNull);
      await b.engine.syncNow();
      expect(b.plaid.state.itemId, isNull);
      expect(b.plaid.state.isConnected, isFalse);

      final pushesBeforeDisconnectNoop = server.pushCalls;
      await b.engine.syncNow();
      expect(server.pushCalls, pushesBeforeDisconnectNoop);
      expect(server.store['plaid']?['singleton']?.data['itemId'], isNull);
    },
  );

  test(
    'task completion and visible hours sync; calendar view stays per-device',
    () async {
      final server = FakeSyncClient();
      final phone = _Device(server);
      final desktop = _Device(server);
      await phone.signIn();
      await desktop.signIn();

      final desktopView = desktop.settings.state.defaultCalendarView;
      phone.settings.setDefaultCalendarView(CalendarView.day);
      phone.settings.setDayHours(7, 22);
      phone.nodes.addNode(
        Node(
          id: 'weekly-plan-task',
          title: 'Prepare weekly plan',
          createdAt: DateTime(2026),
        ),
      );
      await phone.engine.syncNow();
      phone.nodes.toggleDone(
        'weekly-plan-task',
        now: DateTime.utc(2026, 10, 18, 14),
      );
      await phone.engine.syncNow();

      await desktop.engine.syncNow();

      // The phone's day default never roams: each device keeps its own
      // visible window (refs #50).
      expect(desktop.settings.state.defaultCalendarView, desktopView);
      expect(
        server.store['settings']?['singleton']?.data.containsKey(
          'defaultCalendarView',
        ),
        isFalse,
      );
      // Visible hours and the completed task still sync across devices.
      expect(desktop.settings.state.dayStartHour, 7);
      expect(desktop.settings.state.dayEndHour, 22);
      expect(desktop.nodes.byId('weekly-plan-task')?.isDone, isTrue);
      expect(
        desktop.nodes.byId('weekly-plan-task')?.completedAt?.toUtc(),
        DateTime.utc(2026, 10, 18, 14),
      );
    },
  );

  test(
    'a local mutation triggers an automatic sync without the timer',
    () async {
      final server = FakeSyncClient();
      final a = _Device(server);
      final b = _Device(server);
      await a.signIn();
      await b.signIn();
      a.engine.startAutoSyncOnChanges(
        debounce: const Duration(milliseconds: 10),
      );
      addTearDown(a.engine.stopAutoSyncOnChanges);

      a.nodes.addNode(
        Node(id: 't1', title: 'Buy milk', createdAt: DateTime(2026)),
      );

      // No manual syncNow: the debounced watcher pushes the edit on its own.
      await Future.delayed(const Duration(milliseconds: 500));
      expect(server.store['nodes']?['t1']?.data['title'], 'Buy milk');
      // The follow-up pull lands no new records, so nothing retriggers:
      // exactly one push, no sync storm.
      expect(server.pushCalls, 1);

      await b.engine.syncNow();
      expect(b.nodes.byId('t1')?.title, 'Buy milk');
    },
  );

  test(
    'a running timer survives a conflicting pull (server-wins except timers)',
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
      expect(live.timerStartedAt!.isAtSameMomentAs(t0), isTrue);
      expect(
        server.store['nodes']?['t1']?.data['timerStartedAt'],
        t0.toUtc().toIso8601String(),
      );
    },
  );

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
    expect(
      b.nodes
          .byId('t1')!
          .timerStartedAt!
          .isAtSameMomentAs(DateTime(2026, 9, 12, 8, 30)),
      isTrue,
    );
    await a.engine.syncNow();
    expect(
      a.nodes
          .byId('t1')!
          .timerStartedAt!
          .isAtSameMomentAs(DateTime(2026, 9, 12, 8, 30)),
      isTrue,
    );
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
    expect(
      live.actualStart!.isAtSameMomentAs(DateTime(2026, 9, 12, 9)),
      isTrue,
    );
    expect(
      live.actualEnd!.isAtSameMomentAs(DateTime(2026, 9, 12, 9, 30)),
      isTrue,
    );
  });

  test(
    'a newer local run keeps an older run recorded on another device',
    () async {
      final server = FakeSyncClient();
      final a = _Device(server);
      final b = _Device(server);
      await a.signIn();
      await b.signIn();

      a.nodes.addNode(Node(id: 't1', title: 'v1', createdAt: DateTime(2026)));
      await a.engine.syncNow();
      await b.engine.syncNow(); // B baselines on the empty node

      // B records a run and pushes it.
      b.nodes.startTracking('t1', now: DateTime(2026, 9, 12, 10));
      b.nodes.stopTracking('t1', now: DateTime(2026, 9, 12, 10, 30));
      await b.engine.syncNow();

      // A records a newer run while offline (no push yet).
      a.nodes.startTracking('t1', now: DateTime(2026, 9, 12, 11));
      a.nodes.stopTracking('t1', now: DateTime(2026, 9, 12, 11, 30));

      // The pull must not erase A's newer run, and must not drop B's either.
      await a.engine.syncNow();

      final sessions = a.nodes.byId('t1')!.recordedSessions;
      expect(sessions, hasLength(2));
      expect(sessions.first.start, DateTime(2026, 9, 12, 10));
      expect(sessions.last.start, DateTime(2026, 9, 12, 11));
      expect(sessions.last.end, DateTime(2026, 9, 12, 11, 30));
      // The aggregate span covers both runs for older readers.
      final live = a.nodes.byId('t1')!;
      expect(live.actualStart, DateTime(2026, 9, 12, 10));
      expect(live.actualEnd, DateTime(2026, 9, 12, 11, 30));
      // The union is pushed back so B converges on both runs too.
      expect(server.store['nodes']?['t1']?.data['sessions'], hasLength(2));
      await b.engine.syncNow();
      expect(b.nodes.byId('t1')!.recordedSessions, hasLength(2));
    },
  );

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
    expect(live.timerStartedAt!.isAtSameMomentAs(t0), isTrue);
  });

  test('contentHash is stable and sensitive', () {
    expect(contentHash(const {'a': 1}), contentHash(const {'a': 1}));
    expect(contentHash(const {'a': 1}), isNot(contentHash(const {'a': 2})));
  });

  test(
    'switching accounts or signing out never leaks previous user data into next account',
    () async {
      final server = FakeSyncClient();
      final shared = _Device(server);

      await shared.auth.login('alice@example.com', 'password123');
      shared.nodes.addNode(
        Node(
          id: 'alice-secret',
          title: 'Alice secret task',
          createdAt: DateTime(2026),
        ),
      );
      await shared.engine.syncNow();
      expect(server.store['nodes']?.containsKey('alice-secret'), isTrue);

      // Case 2: Alice also adds an UNSYNCED offline item before signing out, then
      // the app restarts (fresh SyncEngine constructed from persisted SyncMetaCubit)
      // and Bob signs in. Zero of Alice's items leak to Bob's cloud, AND Alice's
      // unsynced item is preserved in SyncMetaCubit.accountSnapshots across the
      // restart so it comes back when Alice signs back in.
      shared.nodes.addNode(
        Node(
          id: 'alice-unsynced',
          title: 'Offline draft',
          createdAt: DateTime(2026),
        ),
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
      rehydratedMeta
          .reset(); // AuthPage resets cursor/items, preserving lastEmail
      await restartedEngine.syncNow();

      expect(shared.nodes.byId('alice-secret'), isNull);
      expect(shared.nodes.byId('alice-unsynced'), isNull);
      expect(
        server.store['nodes']?.containsKey('alice-secret') ?? false,
        isFalse,
      );
      expect(
        server.store['nodes']?.containsKey('alice-unsynced') ?? false,
        isFalse,
      );

      // When Alice signs back in later, her unsynced offline item is restored
      // from the persisted snapshot!
      await shared.auth.login('alice@example.com', 'password123');
      rehydratedMeta.reset();
      await restartedEngine.syncNow();
      expect(shared.nodes.byId('alice-unsynced')?.title, 'Offline draft');
    },
  );

  test(
    'sign out, edit offline, same-account re-login keeps the offline edit',
    () async {
      final server = FakeSyncClient();
      final d = _Device(server);
      await d.signIn();
      d.nodes.addNode(Node(id: 't1', title: 'v1', createdAt: DateTime(2026)));
      await d.engine.syncNow();
      expect(server.store['nodes']?.containsKey('t1'), isTrue);

      // Sign out (keeps on-device data), edit + add while signed out.
      d.engine.signOut();
      d.nodes.updateNode(d.nodes.byId('t1')!.copyWith(title: 'offline edit'));
      d.nodes.addNode(
        Node(id: 't2', title: 'offline new', createdAt: DateTime(2026)),
      );

      // Same account signs back in (AuthPage resets cursor/items).
      await d.auth.login('a@example.com', 'password123');
      d.meta.reset();
      await d.engine.syncNow();

      // Nothing is wiped to the sign-out-time snapshot; both items push.
      expect(d.nodes.byId('t1')?.title, 'offline edit');
      expect(d.nodes.byId('t2')?.title, 'offline new');
      expect(server.store['nodes']?['t1']?.data['title'], 'offline edit');
      expect(server.store['nodes']?.containsKey('t2'), isTrue);
    },
  );

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

  test(
    'signOut(clearLocalData: true) wipes local cubits; re-login restores',
    () async {
      final server = FakeSyncClient();
      final d = _Device(server);
      await d.auth.login('a@example.com', 'password123');
      d.nodes.addNode(Node(id: 't1', title: 'v1', createdAt: DateTime(2026)));
      await d.engine.syncNow();
      expect(server.store['nodes']?.containsKey('t1'), isTrue);

      // Unsynced offline item, then sign out removing on-device data.
      d.nodes.addNode(
        Node(id: 't2', title: 'offline only', createdAt: DateTime(2026)),
      );
      d.engine.signOut(clearLocalData: true);
      expect(d.nodes.byId('t1'), isNull);
      expect(d.nodes.byId('t2'), isNull);
      expect(d.plaid.state.isConnected, isFalse);
      expect(d.meta.state.items, isEmpty);
      expect(d.meta.state.lastEmail, isNull);
      expect(
        d.meta.state.accountSnapshots.containsKey('a@example.com'),
        isTrue,
      );

      // Same account signs back in (AuthPage resets cursor/items): the
      // sign-out snapshot backfills local state and the previously-unsynced
      // item uploads instead of being lost with the wipe.
      await d.auth.login('a@example.com', 'password123');
      d.meta.reset();
      await d.engine.syncNow();
      expect(d.nodes.byId('t1')?.title, 'v1');
      expect(d.nodes.byId('t2')?.title, 'offline only');
      expect(server.store['nodes']?.containsKey('t2'), isTrue);
    },
  );

  test(
    'returning to account A reseeds meta so conflicts merge instead of clobber',
    () async {
      final server = FakeSyncClient();
      final shared = _Device(server);

      // Alice syncs t1, then makes an offline edit + an offline-only t2.
      await shared.auth.login('alice@example.com', 'password123');
      shared.nodes.addNode(
        Node(id: 't1', title: 'v1', createdAt: DateTime(2026)),
      );
      await shared.engine.syncNow();
      expect(server.store['nodes']?.containsKey('t1'), isTrue);
      shared.nodes.updateNode(
        shared.nodes.byId('t1')!.copyWith(title: 'A edit'),
      );
      shared.nodes.addNode(
        Node(id: 't2', title: 'Offline only', createdAt: DateTime(2026)),
      );
      shared.engine.signOut();

      // Fresh engine over rehydrated meta (simulates app restart).
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

      // Bob uses the device meanwhile; server-side change to t1 lands from
      // another device while Alice is away.
      server.store.clear();
      await shared.auth.login('bob@example.com', 'password123');
      rehydratedMeta.reset();
      await restartedEngine.syncNow();
      expect(shared.nodes.byId('t1'), isNull);
      expect(shared.nodes.byId('t2'), isNull);

      // Seed the server-side newer version of t1 directly.
      server.store['nodes'] = {
        't1': _Row(
          {'id': 't1', 'title': 'Server edit'},
          false,
          DateTime.utc(2026, 9, 13),
        ),
      };

      // Alice returns: offline-only t2 must survive and push; t1 is a true
      // conflict (both sides edited) so documented server-wins applies but
      // the merge runs through the normal conflict path with reseeded meta.
      await shared.auth.login('alice@example.com', 'password123');
      rehydratedMeta.reset();
      await restartedEngine.syncNow();
      expect(shared.nodes.byId('t2')?.title, 'Offline only');
      expect(shared.nodes.byId('t1')?.title, 'Server edit');
      expect(server.store['nodes']?.containsKey('t2'), isTrue);
    },
  );

  test(
    'preserved running timer is pushed to the server on the same sync',
    () async {
      final server = FakeSyncClient();
      final a = _Device(server);
      final b = _Device(server);
      await a.signIn();
      await b.signIn();

      a.nodes.addNode(Node(id: 't1', title: 'v1', createdAt: DateTime(2026)));
      await a.engine.syncNow();
      await b.engine.syncNow(); // B baselines on v1

      // A starts a timer but has not pushed yet.
      final t0 = DateTime(2026, 9, 12, 9);
      a.nodes.startTracking('t1', now: t0);

      // B renames and syncs: the server copy advances without the timer.
      b.nodes.updateNode(b.nodes.byId('t1')!.copyWith(title: 'B edit'));
      await b.engine.syncNow();

      // A's pull keeps the live timer AND the same sync pushes it back so
      // the server (and B) learn the start instead of dropping it forever.
      await a.engine.syncNow();
      expect(a.nodes.byId('t1')?.isTracking, isTrue);

      final stored = server.store['nodes']?['t1']?.data;
      expect(stored, isNotNull);
      expect(stored!['title'], 'B edit');
      expect(stored['timerStartedAt'], isNotNull);
      expect(DateTime.parse(stored['timerStartedAt'] as String).toLocal(), t0);

      await b.engine.syncNow();
      expect(b.nodes.byId('t1')?.isTracking, isTrue);
      expect(b.nodes.byId('t1')?.timerStartedAt, t0);
    },
  );

  test('identical change on both sides does not push twice', () async {
    final server = FakeSyncClient();
    final a = _Device(server);
    final b = _Device(server);
    await a.signIn();
    await b.signIn();

    a.nodes.addNode(Node(id: 't1', title: 'v1', createdAt: DateTime(2026)));
    await a.engine.syncNow();
    await b.engine.syncNow(); // both baselined on v1

    // Both sides deterministically reach the same content: B pushes it,
    // A makes the same edit offline.
    b.nodes.updateNode(b.nodes.byId('t1')!.copyWith(title: 'same'));
    await b.engine.syncNow();
    a.nodes.updateNode(a.nodes.byId('t1')!.copyWith(title: 'same'));

    // The pull already matches local state: meta refreshes to the server
    // hash, so the push phase has nothing to send.
    final before = server.clock;
    await a.engine.syncNow();
    expect(a.nodes.byId('t1')?.title, 'same');
    expect(server.clock, before);

    // Steady state stays quiet: a second clean sync also pushes nothing.
    await a.engine.syncNow();
    expect(server.clock, before);
  });

  test('signOut(clearLocalData: true) preserves the waterfall singleton '
      'on re-login instead of pushing defaults over the cloud copy', () async {
    final server = FakeSyncClient();
    final d = _Device(server);
    await d.auth.login('a@example.com', 'password123');
    d.waterfall.applySyncedConfig(const {'startingBalance': 1234.5});
    d.nodes.addNode(Node(id: 't1', title: 'v1', createdAt: DateTime(2026)));
    await d.engine.syncNow();
    expect(
      server.store['waterfall']?['singleton']?.data['startingBalance'],
      1234.5,
    );

    d.engine.signOut(clearLocalData: true);
    expect(d.waterfall.state.startingBalance, 0.0);

    await d.auth.login('a@example.com', 'password123');
    d.meta.reset();
    await d.engine.syncNow();
    // Restored from the sign-out snapshot ...
    expect(d.waterfall.state.startingBalance, 1234.5);
    // ... and the wiped defaults never reached the cloud copy.
    expect(
      server.store['waterfall']?['singleton']?.data['startingBalance'],
      1234.5,
    );
  });

  test('signOut(clearLocalData: true) with no sync baseline still restores '
      'offline work on re-login', () async {
    final server = FakeSyncClient();
    final d = _Device(server);
    await d.auth.login('a@example.com', 'password123');
    // The first pull never completes: no cursor, no item meta.
    d.nodes.addNode(
      Node(id: 't1', title: 'offline only', createdAt: DateTime(2026)),
    );
    expect(d.meta.state.cursor, isNull);
    expect(d.meta.state.items, isEmpty);

    d.engine.signOut(clearLocalData: true);
    expect(d.nodes.byId('t1'), isNull);

    await d.auth.login('a@example.com', 'password123');
    d.meta.reset();
    await d.engine.syncNow();
    expect(d.nodes.byId('t1')?.title, 'offline only');
    expect(server.store['nodes']?.containsKey('t1'), isTrue);
  });

  test('an incomplete paged pull never advances the stored cursor', () async {
    final server = _IncompletePullClient();
    final d = _Device(server);
    await d.signIn();

    d.nodes.addNode(Node(id: 't1', title: 'v1', createdAt: DateTime(2026)));
    await d.engine.syncNow();
    expect(d.engine.status.value, EngineStatus.idle);
    final cursor = d.meta.state.cursor;
    expect(cursor, isNotNull);

    // The next pull fails partway (fail-closed like the real paged client):
    // the stored cursor must stay put so the skipped rows arrive later.
    d.nodes.addNode(Node(id: 't2', title: 'v2', createdAt: DateTime(2026)));
    server.failPull = true;
    await d.engine.syncNow();
    expect(d.engine.status.value, EngineStatus.error);
    expect(d.meta.state.cursor, cursor);

    // Once the server answers fully, everything lands and the cursor moves on.
    server.failPull = false;
    await d.engine.syncNow();
    expect(d.engine.status.value, EngineStatus.idle);
    expect(d.meta.state.cursor, isNot(cursor));
    expect(server.store['nodes']?.containsKey('t1'), isTrue);
    expect(server.store['nodes']?.containsKey('t2'), isTrue);
  });
}
