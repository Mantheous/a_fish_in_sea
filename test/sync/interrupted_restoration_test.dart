import 'dart:async';

import 'package:a_fish_in_sea/common/persistence/stable_storage_keys.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/reporting/model/place.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

import 'support/delayed_storage.dart';
import 'support/sync_test_device.dart';

void main() {
  for (final beforeApply in [true, false]) {
    test('never-synced restoration interrupted '
        '${beforeApply ? 'after ownership' : 'during collection persistence'} '
        'retries after restart and survives another Remove', () async {
      final storage = DelayedStorage();
      HydratedBloc.storage = storage;
      final server = FakeSyncClient();
      final d = SyncTestDevice(server);
      await d.signIn();
      d.nodes.addNode(
        Node(id: 'draft', title: 'offline work', createdAt: DateTime(2026)),
      );
      d.places.addPlace(
        const Place(id: 'home', name: 'A home', lat: 1, lng: 2),
      );
      await d.engine.signOut(clearLocalData: true);

      storage.pauseRestorationIntent = beforeApply;
      storage.pauseDomainWrites = !beforeApply;
      // The old process stops at this storage await and never resumes.
      unawaited(d.signIn());
      await Future<void>.delayed(Duration.zero);
      final persisted = storage.data[StableStorageKeys.syncMeta] as Map;
      expect(persisted['lastEmail'], 'a@example.com');
      expect(persisted['pendingRestoration'], isTrue);
      expect(d.auth.state.isSignedIn, isFalse);
      expect(d.nodes.byId('draft') != null, !beforeApply);
      expect((storage.data[StableStorageKeys.node] as Map)['nodes'], isEmpty);

      final restartedStorage = DelayedStorage()..data.addAll(storage.data);
      HydratedBloc.storage = restartedStorage;
      final restarted = SyncTestDevice(server);
      expect(restarted.meta.state.pendingRestoration, isTrue);
      expect(restarted.nodes.state, isEmpty);
      var incompleteLogin = false;
      final sub = restarted.auth.stream.listen((state) {
        if (state.isSignedIn) {
          incompleteLogin |=
              restarted.nodes.byId('draft') == null ||
              restarted.places.state.isEmpty ||
              restarted.meta.state.pendingRestoration;
        }
      });
      await restarted.signIn();
      expect(incompleteLogin, isFalse);
      expect(restarted.nodes.byId('draft')?.title, 'offline work');
      expect(restarted.places.state.single.id, 'home');
      final completed =
          restartedStorage.data[StableStorageKeys.syncMeta] as Map;
      expect(completed['pendingRestoration'], isNot(true));
      expect(
        (restartedStorage.data[StableStorageKeys.node] as Map)['nodes'],
        hasLength(1),
      );

      // No sync has occurred: the recovery snapshot is still the only backup.
      await restarted.engine.signOut(clearLocalData: true);
      expect(restarted.nodes.state, isEmpty);
      await restarted.signIn();
      expect(restarted.nodes.byId('draft')?.title, 'offline work');
      await restarted.engine.syncNow();
      expect(server.store['nodes']?['draft']?.data['title'], 'offline work');
      expect(server.store['places']?['home']?.data['name'], 'A home');
      await sub.cancel();
    });
  }

  test(
    'sign-out before interrupted restoration retries cannot erase recovery',
    () async {
      final storage = DelayedStorage();
      HydratedBloc.storage = storage;
      final server = FakeSyncClient();
      final d = SyncTestDevice(server);
      await d.signIn();
      d.nodes.addNode(
        Node(id: 'draft', title: 'offline', createdAt: DateTime(2026)),
      );
      await d.engine.signOut(clearLocalData: true);
      storage.pauseRestorationIntent = true;
      unawaited(d.signIn());
      await Future<void>.delayed(Duration.zero);

      HydratedBloc.storage = DelayedStorage()..data.addAll(storage.data);
      final restarted = SyncTestDevice(server);
      // Sign out immediately, without completing another login first.
      await restarted.engine.signOut(clearLocalData: true);
      expect(
        restarted
            .meta
            .state
            .accountSnapshots['a@example.com']
            ?.collections['nodes']?['draft']?['title'],
        'offline',
      );
      await restarted.signIn();
      expect(restarted.nodes.byId('draft')?.title, 'offline');
    },
  );

  test(
    'sign-out waits for an in-flight restoration before releasing ownership',
    () async {
      final storage = DelayedStorage();
      HydratedBloc.storage = storage;
      final server = FakeSyncClient();
      final d = SyncTestDevice(server);
      await d.signIn();
      d.nodes.addNode(
        Node(id: 'draft', title: 'offline', createdAt: DateTime(2026)),
      );
      await d.engine.signOut(clearLocalData: true);

      storage.pauseDomainWrites = true;
      final restoring = d.auth.login('a@example.com', 'password123');
      await Future<void>.delayed(Duration.zero);
      expect(d.meta.state.pendingRestoration, isTrue);
      expect(d.nodes.byId('draft'), isNotNull);
      final removal = d.engine.signOut(clearLocalData: true);
      final incoming = d.auth.login('b@example.com', 'password123');
      await Future<void>.delayed(Duration.zero);
      expect(d.auth.state.isSignedIn, isFalse);
      expect(d.meta.state.pendingRestoration, isTrue);
      expect(d.meta.state.lastEmail, 'a@example.com');
      d.nodes.addNode(
        Node(id: 'late', title: 'private', createdAt: DateTime(2026)),
      );
      expect(d.nodes.byId('late'), isNull);

      storage.pauseDomainWrites = false;
      storage.paused.complete();
      expect(await restoring, isFalse); // Sign-out cancelled the earlier login.
      await removal;
      expect(await incoming, isTrue);
      expect(d.nodes.state, isEmpty);
      expect(d.meta.state.pendingRestoration, isFalse);
      await d.engine.syncNow();
      expect(server.store['nodes'] ?? {}, isEmpty);
      server.store.clear();
      await d.signIn();
      expect(d.nodes.byId('draft')?.title, 'offline');
      expect(d.nodes.byId('late'), isNull);
    },
  );
}
