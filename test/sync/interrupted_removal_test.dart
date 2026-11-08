import 'dart:async';
import 'dart:convert';

import 'package:a_fish_in_sea/common/persistence/stable_storage_keys.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/reporting/model/place.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

import 'support/sync_test_device.dart';

/// Domain writes can stop while sync metadata still persists, matching the
/// separate HydratedBloc keys on a device interrupted during removal.
class _InterruptedStorage implements Storage {
  final data = <String, dynamic>{};
  final paused = Completer<void>();
  final metadataPaused = Completer<void>();
  bool pauseDomainWrites = false;
  bool pauseMetadataWrites = false;
  bool domainWriteStarted = false;

  @override
  dynamic read(String key) => data[key];

  @override
  Future<void> write(String key, dynamic value) async {
    if (pauseMetadataWrites && key == StableStorageKeys.syncMeta) {
      await metadataPaused.future;
    }
    if (pauseDomainWrites && key != StableStorageKeys.syncMeta) {
      domainWriteStarted = true;
      await paused.future;
    }
    data[key] = jsonDecode(jsonEncode(value));
  }

  @override
  Future<void> delete(String key) async => data.remove(key);
  @override
  Future<void> clear() async => data.clear();
  @override
  Future<void> close() async {}
}

void main() {
  test('Remove waits for the snapshot before clearing any collection', () async {
    final storage = _InterruptedStorage();
    HydratedBloc.storage = storage;
    final d = SyncTestDevice(FakeSyncClient());
    await d.signIn();
    d.nodes.addNode(
      Node(id: 'draft', title: 'unsynced', createdAt: DateTime(2026)),
    );
    storage.pauseMetadataWrites = true;

    final removal = d.engine.signOut(clearLocalData: true);
    await Future<void>.delayed(Duration.zero);
    expect(d.nodes.byId('draft'), isNotNull);
    expect(d.auth.state.isSignedIn, isTrue);
    final durableMeta = storage.data[StableStorageKeys.syncMeta] as Map;
    expect(durableMeta['pendingRemoval'], isNot(true));

    storage.pauseMetadataWrites = false;
    storage.metadataPaused.complete();
    await removal;
    expect(d.nodes.state, isEmpty);
    expect(d.auth.state.isSignedIn, isFalse);
    final completedMeta = storage.data[StableStorageKeys.syncMeta] as Map;
    expect(completedMeta['lastEmail'], isNull);
    expect(completedMeta['pendingRemoval'], isNot(true));
    expect(
      completedMeta['accountSnapshots']['a@example.com']['collections']['nodes']['draft']['title'],
      'unsynced',
    );
  });

  for (final returningEmail in ['b@example.com', 'a@example.com']) {
    test(
      'interrupted Remove then restart as $returningEmail isolates and recovers',
      () async {
        final storage = _InterruptedStorage();
        HydratedBloc.storage = storage;
        final server = FakeSyncClient();
        final d = SyncTestDevice(server);
        await d.signIn();
        d.nodes.addNode(
          Node(id: 'secret', title: 'A unsynced', createdAt: DateTime(2026)),
        );
        d.places.addPlace(
          const Place(id: 'home', name: 'A home', lat: 1, lng: 2),
        );

        storage.pauseDomainWrites = true;
        // These futures model a terminated process: domain writes never finish.
        unawaited(d.engine.signOut(clearLocalData: true));
        await Future<void>.delayed(Duration.zero);
        expect(storage.domainWriteStarted, isTrue);
        final persisted = storage.data[StableStorageKeys.syncMeta] as Map;
        expect(persisted['lastEmail'], 'a@example.com');
        expect(persisted['pendingRemoval'], isTrue);
        expect(persisted['cursor'], isNull);
        expect(persisted['items'], isEmpty);
        expect(
          (storage.data[StableStorageKeys.node] as Map)['nodes'],
          hasLength(1),
        );
        expect(
          (storage.data[StableStorageKeys.places] as Map)['places'],
          hasLength(1),
        );

        // Restart from exactly the acknowledged writes, with A's collections
        // still present. Constructing the engine hides them before any UI.
        final restartedStorage = _InterruptedStorage();
        restartedStorage.data.addAll(
          jsonDecode(jsonEncode(storage.data)) as Map<String, dynamic>,
        );
        HydratedBloc.storage = restartedStorage;
        final restarted = SyncTestDevice(server);
        expect(restarted.nodes.state, isEmpty);
        expect(restarted.places.state, isEmpty);
        expect(restarted.meta.state.pendingRemoval, isTrue);
        restarted.auth.logout();

        var exposedA = false;
        final subscription = restarted.auth.stream.listen((state) {
          if (state.isSignedIn && state.email == 'b@example.com') {
            exposedA |=
                restarted.nodes.byId('secret') != null ||
                restarted.places.state.isNotEmpty;
          }
        });
        await restarted.auth.login(returningEmail, 'password123');
        restarted.meta.reset();
        await restarted.engine.syncNow();
        expect(exposedA, isFalse);
        expect(restarted.meta.state.pendingRemoval, isFalse);
        if (returningEmail == 'b@example.com') {
          expect(restarted.nodes.state, isEmpty);
          expect(restarted.places.state, isEmpty);
          expect(server.store['nodes']?['secret'], isNull);
          expect(server.store['places']?['home'], isNull);
          // A's unsynced recovery survives B's full session and another switch.
          server.store.clear();
          await restarted.signIn();
          restarted.meta.reset();
          await restarted.engine.syncNow();
        }
        expect(restarted.nodes.byId('secret')?.title, 'A unsynced');
        expect(restarted.places.state.single.id, 'home');
        expect(server.store['nodes']?['secret']?.data['title'], 'A unsynced');
        await subscription.cancel();
      },
    );
  }
}
