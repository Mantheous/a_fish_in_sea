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
  Future<List<SyncRecord>> push(List<Map<String, dynamic>> changes) async {
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
    return applied;
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

  test('contentHash is stable and sensitive', () {
    expect(
      contentHash(const {'a': 1}),
      contentHash(const {'a': 1}),
    );
    expect(contentHash(const {'a': 1}), isNot(contentHash(const {'a': 2})));
  });
}
