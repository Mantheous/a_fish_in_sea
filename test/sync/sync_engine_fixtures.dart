part of 'sync_engine_test.dart';

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

  _Device(
    this.server, {
    CalendarCubit? calendar,
    NodeCubit? nodeCubit,
    FeedCubit? feedCubit,
    GoogleCalendarService? google,
  }) {
    auth = AuthCubit(client: () => server);
    meta = SyncMetaCubit();
    nodes = nodeCubit ?? NodeCubit();
    events = calendar ?? CalendarCubit();
    feeds =
        feedCubit ??
        FeedCubit(
          calendarCubit: events,
          nodeCubit: nodes,
          icalService: IcalService(),
          googleService:
              google ??
              GoogleCalendarService(baseUrl: () => '', userId: () => ''),
          proxyBase: () => '',
        );
    settings = SettingsCubit();
    final transactions = TransactionsCubit();
    plaid = _TestPlaidCubit();
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
