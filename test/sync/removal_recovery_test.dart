import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/reporting/model/place.dart';
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

  test('signOut(clearLocalData: true) preserves the waterfall singleton '
      'on re-login instead of pushing defaults over the cloud copy', () async {
    final server = FakeSyncClient();
    final d = SyncTestDevice(server);
    await d.auth.login('a@example.com', 'password123');
    d.waterfall.applySyncedConfig(const {'startingBalance': 1234.5});
    d.nodes.addNode(Node(id: 't1', title: 'v1', createdAt: DateTime(2026)));
    await d.engine.syncNow();
    expect(
      server.store['waterfall']?['singleton']?.data['startingBalance'],
      1234.5,
    );

    await d.engine.signOut(clearLocalData: true);
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
    final d = SyncTestDevice(server);
    await d.auth.login('a@example.com', 'password123');
    // The first pull never completes: no cursor, no item meta.
    d.nodes.addNode(
      Node(id: 't1', title: 'offline only', createdAt: DateTime(2026)),
    );
    expect(d.meta.state.cursor, isNull);
    expect(d.meta.state.items, isEmpty);

    await d.engine.signOut(clearLocalData: true);
    expect(d.nodes.byId('t1'), isNull);

    await d.auth.login('a@example.com', 'password123');
    d.meta.reset();
    await d.engine.syncNow();
    expect(d.nodes.byId('t1')?.title, 'offline only');
    expect(server.store['nodes']?.containsKey('t1'), isTrue);
  });

  test('Remove sign-out persists the recovery snapshot before wiping so a '
      'restart restores unsynced work', () async {
    final server = FakeSyncClient();
    final d = SyncTestDevice(server);
    await d.auth.login('a@example.com', 'password123');
    d.nodes.addNode(
      Node(id: 't1', title: 'unsynced', createdAt: DateTime(2026)),
    );

    await d.engine.signOut(clearLocalData: true);
    expect(d.nodes.byId('t1'), isNull);

    // The serialized bookkeeping already holds the snapshot with an empty
    // baseline. A crash right after this point therefore cannot leave empty
    // cubits paired with a live baseline (which would tombstone the cloud).
    final persisted = d.meta.fromJson(d.meta.toJson(d.meta.state))!;
    expect(persisted.lastEmail, isNull);
    expect(persisted.cursor, isNull);
    expect(persisted.items, isEmpty);
    expect(
      persisted
          .accountSnapshots['a@example.com']
          ?.collections['nodes']?['t1']?['title'],
      'unsynced',
    );

    // Restart with the wiped cubits and rehydrated bookkeeping, re-login.
    final freshMeta = SyncMetaCubit();
    freshMeta.emit(persisted);
    final restarted = d.engineOver(freshMeta);
    await d.auth.login('a@example.com', 'password123');
    freshMeta.reset(); // AuthPage resets cursor/items, preserving lastEmail
    await restarted.syncNow();

    expect(d.nodes.byId('t1')?.title, 'unsynced');
    expect(server.store['nodes']?.containsKey('t1'), isTrue);
  });

  test(
    'a Keep sign-out never resurrects work deleted after a failed pull',
    () async {
      final server = IncompletePullClient();
      final d = SyncTestDevice(server);
      await d.auth.login('a@example.com', 'password123');
      d.nodes.addNode(
        Node(id: 't1', title: 'offline only', createdAt: DateTime(2026)),
      );

      // Keep: local data stays and lastEmail records that this was not a wipe.
      await d.engine.signOut();
      await d.auth.login('a@example.com', 'password123');
      d.meta.reset();

      // The first pull never completes, so no cursor/item meta is recorded.
      server.failPull = true;
      await d.engine.syncNow();
      expect(d.engine.status.value, EngineStatus.error);

      // Deleting the only task must survive the retry: the sign-out snapshot
      // must not be re-applied over a deliberate deletion.
      d.nodes.deleteNode('t1');
      server.failPull = false;
      await d.engine.syncNow();

      expect(d.nodes.byId('t1'), isNull);
      expect(server.store['nodes']?.containsKey('t1') ?? false, isFalse);
    },
  );

  test(
    'Remove clears roamed settings so the next account starts empty',
    () async {
      final server = FakeSyncClient();
      final d = SyncTestDevice(server);
      await d.auth.login('alice@example.com', 'password123');
      d.settings.setDayHours(7, 22);
      d.settings.setTrackingIntervalMinutes(10);
      await d.engine.syncNow();
      expect(server.store['settings']?['singleton']?.data['dayStartHour'], 7);

      await d.engine.signOut(clearLocalData: true);
      // Roamed settings are gone; per-device view stays as it was.
      expect(d.settings.state.dayStartHour, 6);
      expect(d.settings.state.dayEndHour, 24);
      expect(d.settings.state.trackingIntervalMinutes, 5);
      final perDeviceView = d.settings.state.defaultCalendarView;

      // Bob is a fresh account on the same device: nothing of Alice's roams.
      server.store.clear();
      await d.auth.login('bob@example.com', 'password123');
      d.meta.reset();
      await d.engine.syncNow();

      final bobsSettings = server.store['settings']?['singleton']?.data;
      expect(bobsSettings?['dayStartHour'], 6);
      expect(bobsSettings?['dayEndHour'], 24);
      expect(bobsSettings?['trackingIntervalMinutes'], 5);
      expect(d.settings.state.defaultCalendarView, perDeviceView);
    },
  );

  test(
    'a snapshot with an empty collection never tombstones the cloud copy',
    () async {
      final server = FakeSyncClient();
      final d = SyncTestDevice(server);
      await d.auth.login('a@example.com', 'password123');
      for (var i = 0; i < 4; i++) {
        d.places.addPlace(
          Place(id: 'p$i', name: 'Place $i', lat: 40.0 + i, lng: -111.0 - i),
        );
      }
      await d.engine.syncNow();
      expect(server.store['places']?.length, 4);

      // Local store lost (e.g. failed hydrate) while sync bookkeeping survives.
      d.places.applyJson(const {'places': <dynamic>[]});
      await d.engine.signOut(clearLocalData: true);

      // Restart over rehydrated meta, re-login: the full pull recovers the
      // cloud copy instead of tombstoning the four ids this device cannot show.
      final freshMeta = d.rehydratedMeta();
      final restarted = d.engineOver(freshMeta);
      await d.auth.login('a@example.com', 'password123');
      freshMeta.reset();
      await restarted.syncNow();

      expect(server.store['places']?.length, 4);
      expect(d.places.state.length, 4);
    },
  );
}
