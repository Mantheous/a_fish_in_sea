part of 'sync_engine_test.dart';

void registerTimerSyncTests() {
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

  registerRecordingDeletionTests();
}

Map<String, dynamic> _recordingItem(_Device device, String collection) =>
    collection == 'nodes'
    ? device.nodes.byId('recorded')!.toJson()
    : device.events.state.single.toJson();

void _writeRecordingItem(
  _Device device,
  String collection,
  Map<String, dynamic> data,
) {
  if (collection == 'nodes') {
    device.nodes.applyJson({
      'nodes': [data],
    });
  } else {
    device.events.applyJson({
      'events': [data],
    });
  }
}

Map<String, dynamic> _withRecordings(
  Map<String, dynamic> data,
  List<TimeSession> sessions,
) {
  final span = sessionSpan(sessions);
  return {
    ...data,
    'sessions': [for (final session in sessions) session.toJson()],
    'actualStart': span?.start.toUtc().toIso8601String(),
    'actualEnd': span?.end.toUtc().toIso8601String(),
  };
}

void registerRecordingDeletionTests() {
  final first = TimeSession(
    id: 'shared:first',
    start: DateTime(2026, 9, 12, 9),
    end: DateTime(2026, 9, 12, 9, 20),
  );
  final second = TimeSession(
    id: 'shared:second',
    start: DateTime(2026, 9, 12, 10),
    end: DateTime(2026, 9, 12, 10, 20),
  );
  final unsent = TimeSession(
    id: 'unsent',
    start: DateTime(2026, 9, 12, 11),
    end: DateTime(2026, 9, 12, 11, 20),
  );
  final liveStart = DateTime(2026, 9, 12, 12).toUtc().toIso8601String();

  for (final collection in ['nodes', 'events']) {
    Map<String, dynamic> seed() => _withRecordings(
      collection == 'nodes'
          ? Node(
              id: 'recorded',
              title: 'Recorded task',
              createdAt: DateTime(2026),
            ).toJson()
          : PlannerEvent(
              id: 'recorded',
              subject: 'Recorded event',
              start: DateTime(2026, 9, 12, 9),
              end: DateTime(2026, 9, 12, 10),
            ).toJson(),
      [first, second],
    );

    for (final remaining in [
      <TimeSession>[],
      [second],
    ]) {
      for (final live in [false, true]) {
        test('$collection clean-device deletion converges '
            '(${remaining.length} remaining, live timer: $live)', () async {
          final server = FakeSyncClient();
          final a = _Device(server);
          final b = _Device(server);
          await a.signIn();
          await b.signIn();
          final data = seed();
          if (live) data['timerStartedAt'] = liveStart;
          _writeRecordingItem(a, collection, data);
          await a.engine.syncNow();
          await b.engine.syncNow();

          final baseline = b.meta.state.items['$collection/recorded']!;
          expect(baseline.hash, contentHash(_recordingItem(b, collection)));
          final deleted = _withRecordings(
            _recordingItem(a, collection),
            remaining,
          )..['timerStartedAt'] = null;
          _writeRecordingItem(a, collection, deleted);
          await a.engine.syncNow();
          await b.engine.syncNow();
          await a.engine.syncNow();

          for (final item in [
            _recordingItem(a, collection),
            _recordingItem(b, collection),
            server.store[collection]!['recorded']!.data,
          ]) {
            expect(TimeSession.listFromJson(item['sessions']), remaining);
            expect(item['timerStartedAt'], live ? liveStart : null);
            if (remaining.isEmpty) {
              expect(item['actualStart'], isNull);
              expect(item['actualEnd'], isNull);
            }
          }
          expect(a.engine.status.value, EngineStatus.idle);
          expect(b.engine.status.value, EngineStatus.idle);
        });
      }
    }

    for (final dirty in [false, true]) {
      for (final aggregate in [false, true]) {
        test('$collection legacy omission preserves recordings '
            '(unsent edits: $dirty, legacy span: $aggregate)', () async {
          final server = FakeSyncClient();
          final a = _Device(server);
          final b = _Device(server);
          await a.signIn();
          await b.signIn();
          _writeRecordingItem(a, collection, seed());
          await a.engine.syncNow();
          await b.engine.syncNow();

          if (dirty) {
            final edited = _withRecordings(_recordingItem(b, collection), [
              first,
              second,
              unsent,
            ])..['timerStartedAt'] = liveStart;
            _writeRecordingItem(b, collection, edited);
          }
          final baseline = b.meta.state.items['$collection/recorded']!;
          expect(
            baseline.hash == contentHash(_recordingItem(b, collection)),
            !dirty,
          );
          // Simulate an older device renaming without knowing sessions.
          final legacy = _recordingItem(a, collection)
            ..remove('sessions')
            ..[collection == 'nodes' ? 'title' : 'subject'] = 'Legacy rename';
          if (!aggregate) {
            legacy['actualStart'] = null;
            legacy['actualEnd'] = null;
          }
          await server.push([
            {'collection': collection, 'item_id': 'recorded', 'data': legacy},
          ]);
          await b.engine.syncNow();
          await a.engine.syncNow();
          await b.engine.syncNow();

          for (final item in [
            _recordingItem(a, collection),
            _recordingItem(b, collection),
            server.store[collection]!['recorded']!.data,
          ]) {
            expect(TimeSession.listFromJson(item['sessions']), [
              first,
              second,
              if (dirty) unsent,
            ]);
            expect(item['timerStartedAt'], dirty ? liveStart : null);
            expect(
              item[collection == 'nodes' ? 'title' : 'subject'],
              'Legacy rename',
            );
          }
          expect(a.engine.status.value, EngineStatus.idle);
          expect(b.engine.status.value, EngineStatus.idle);
        });
      }
    }
  }
}
