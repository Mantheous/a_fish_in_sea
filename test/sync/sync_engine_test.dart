import 'package:a_fish_in_sea/common/time/time_session.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:a_fish_in_sea/sync/sync_meta_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:syncfusion_flutter_calendar/calendar.dart';

import 'support/sync_test_device.dart';

part 'sync_engine_timer_cases.dart';

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
    final a = SyncTestDevice(server);
    final b = SyncTestDevice(server);
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
    final a = SyncTestDevice(server);
    final b = SyncTestDevice(server);
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
      final a = SyncTestDevice(server);
      await a.signIn();

      a.nodes.addNode(
        Node(id: 't1', title: 'original', createdAt: DateTime(2026)),
      );
      await a.engine.syncNow();
      a.nodes.updateNode(a.nodes.byId('t1')!.copyWith(title: 'edited'));
      expect(undo.canUndo, isTrue);

      // Another device creates t2 directly on the server (newer than a's
      // cursor, so the next pull delivers it like a background sync would).
      server.store.putIfAbsent('nodes', () => {})['t2'] = SyncRow(
        Node(id: 't2', title: 'from B', createdAt: DateTime(2026)).toJson(),
        false,
        server.tick(),
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
    final a = SyncTestDevice(server);
    final b = SyncTestDevice(server);
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
      final a = SyncTestDevice(server);
      final b = SyncTestDevice(server);
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
    final a = SyncTestDevice(server);
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
      final a = SyncTestDevice(server);
      final b = SyncTestDevice(server);
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
      final phone = SyncTestDevice(server);
      final desktop = SyncTestDevice(server);
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
      final a = SyncTestDevice(server);
      final b = SyncTestDevice(server);
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

  registerTimerSyncTests();

  test('contentHash is stable and sensitive', () {
    expect(contentHash(const {'a': 1}), contentHash(const {'a': 1}));
    expect(contentHash(const {'a': 1}), isNot(contentHash(const {'a': 2})));
  });

  test(
    'preserved running timer is pushed to the server on the same sync',
    () async {
      final server = FakeSyncClient();
      final a = SyncTestDevice(server);
      final b = SyncTestDevice(server);
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
    final a = SyncTestDevice(server);
    final b = SyncTestDevice(server);
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

  test('an incomplete paged pull never advances the stored cursor', () async {
    final server = IncompletePullClient();
    final d = SyncTestDevice(server);
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
