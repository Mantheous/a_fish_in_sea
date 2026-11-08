import 'package:a_fish_in_sea/finances/bloc/plaid_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/transactions_cubit.dart';
import 'package:a_fish_in_sea/finances/bloc/waterfall_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/reporting/bloc/places_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/reporting_cubit.dart';
import 'package:a_fish_in_sea/reporting/bloc/tracking_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:a_fish_in_sea/sync/sync_meta_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

import 'support/sync_test_device.dart';

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

  test(
    'switching accounts or signing out never leaks previous user data into next account',
    () async {
      final server = FakeSyncClient();
      final shared = SyncTestDevice(server);

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
      await shared.engine.signOut();
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
      final d = SyncTestDevice(server);
      await d.signIn();
      d.nodes.addNode(Node(id: 't1', title: 'v1', createdAt: DateTime(2026)));
      await d.engine.syncNow();
      expect(server.store['nodes']?.containsKey('t1'), isTrue);

      // Sign out (keeps on-device data), edit + add while signed out.
      await d.engine.signOut();
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
    final d = SyncTestDevice(server);
    await d.signIn();
    d.nodes.addNode(Node(id: 't1', title: 'v1', createdAt: DateTime(2026)));

    final syncFuture = d.engine.syncNow();
    await d.engine.signOut();
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
      final d = SyncTestDevice(server);
      await d.auth.login('a@example.com', 'password123');
      d.nodes.addNode(Node(id: 't1', title: 'v1', createdAt: DateTime(2026)));
      await d.engine.syncNow();
      expect(server.store['nodes']?.containsKey('t1'), isTrue);

      // Unsynced offline item, then sign out removing on-device data.
      d.nodes.addNode(
        Node(id: 't2', title: 'offline only', createdAt: DateTime(2026)),
      );
      await d.engine.signOut(clearLocalData: true);
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
      final shared = SyncTestDevice(server);

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
      await shared.engine.signOut();

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
        't1': SyncRow(
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
}
