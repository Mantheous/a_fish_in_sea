import 'package:a_fish_in_sea/common/persistence/stable_storage_keys.dart';
import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/reporting/model/place.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:a_fish_in_sea/sync/view/account_transition_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

import 'support/delayed_storage.dart';
import 'support/sync_test_device.dart';

class _FailingStorage extends DelayedStorage {
  bool failMetadata = false;

  @override
  Future<void> write(String key, dynamic value) async {
    if (failMetadata && key == StableStorageKeys.syncMeta) {
      throw StateError('Storage unavailable');
    }
    await super.write(key, value);
  }
}

void main() {
  for (final removal in [true, false]) {
    test('failed ${removal ? 'removal' : 'restoration'} releases the mutation '
        'fence and preserves recovery for a retry', () async {
      final storage = _FailingStorage();
      HydratedBloc.storage = storage;
      final d = SyncTestDevice(FakeSyncClient());
      addTearDown(d.waterfall.close);
      await d.signIn();
      d.nodes.addNode(
        Node(id: 'draft', title: 'A draft', createdAt: DateTime(2026)),
      );
      if (!removal) await d.engine.signOut(clearLocalData: true);
      storage.failMetadata = true;
      if (removal) {
        await expectLater(
          d.engine.signOut(clearLocalData: true),
          throwsStateError,
        );
      } else {
        expect(await d.auth.login('a@example.com', 'password123'), isFalse);
      }
      expect(d.nodes.accountMutationsBlocked, isFalse);
      expect(d.tracking.accountMutationsBlocked, isFalse);
      expect(d.feeds.accountMutationsBlocked, isFalse);
      expect(d.engine.accountTransitioning.value, isFalse);
      storage.failMetadata = false;
      if (removal) await d.engine.signOut(clearLocalData: true);
      await d.signIn();
      expect(d.nodes.byId('draft')?.title, 'A draft');
    });
  }

  testWidgets('removal blocks planner, dialogs, keyboard and Undo through '
      'delayed writes; incoming account waits and receives no outgoing data', (
    tester,
  ) async {
    final storage = DelayedStorage();
    HydratedBloc.storage = storage;
    final server = FakeSyncClient();
    final d = SyncTestDevice(server);
    await d.signIn();
    final undo = UndoCubit();
    addTearDown(undo.close);
    addTearDown(d.waterfall.close);
    d.nodes.addNode(
      Node(id: 'draft', title: 'A private', createdAt: DateTime(2026)),
    );
    d.nodes.addNode(
      Node(id: 'deleted', title: 'A deleted', createdAt: DateTime(2026)),
    );
    d.nodes.deleteNode('deleted');
    d.places.addPlace(const Place(id: 'home', name: 'A home', lat: 1, lng: 2));
    expect(undo.canUndo, isTrue);
    var edits = 0;
    void edit() {
      edits++;
      d.nodes.addNode(
        Node(id: 'late', title: 'A late edit', createdAt: DateTime(2026)),
      );
    }

    await tester.pumpWidget(
      RepositoryProvider<SyncEngine>.value(
        value: d.engine,
        child: MaterialApp(
          builder: (context, child) => AccountTransitionGate(child: child!),
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  FilledButton(
                    onPressed: edit,
                    child: const Text('Edit planner'),
                  ),
                  TextField(onChanged: (_) => edit()),
                  TextButton(onPressed: undo.undo, child: const Text('Undo')),
                  TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => AlertDialog(
                        actions: [
                          TextButton(
                            onPressed: edit,
                            child: const Text('Save open editor'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('Open editor'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();

    storage.pauseMetadataWrites = true;
    storage.pauseDomainWrites = true;
    final removal = d.engine.signOut(clearLocalData: true);
    // These are synchronous: there is no frame or storage acknowledgement yet.
    expect(d.engine.accountTransitioning.value, isTrue);
    expect(d.auth.state.isSignedIn, isFalse);
    expect(undo.canUndo, isFalse);
    d.nodes.addNode(
      Node(id: 'callback', title: 'late callback', createdAt: DateTime(2026)),
    );
    undo.undo();
    expect(d.nodes.byId('callback'), isNull);
    await tester.pump();
    await tester.tapAt(tester.getCenter(find.text('Save open editor')));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(edits, 0);
    expect(d.nodes.byId('draft'), isNotNull); // Snapshot write still blocked.

    storage.pauseMetadataWrites = false;
    storage.metadataPaused.complete();
    await tester.pump();
    expect(storage.domainWriteStarted, isTrue);
    expect(d.nodes.state, isEmpty);
    expect(d.places.state, isEmpty);
    final pending = storage.data[StableStorageKeys.syncMeta] as Map;
    expect(pending['lastEmail'], 'a@example.com');
    expect(pending['pendingRemoval'], isTrue);
    expect(
      pending['accountSnapshots']['a@example.com']['collections']['nodes']['draft']['title'],
      'A private',
    );

    // Programmatic mutations/Undo from already queued controls are fenced too.
    undo.undo();
    d.nodes.addNode(
      Node(id: 'late', title: 'A private', createdAt: DateTime(2026)),
    );
    d.places.addPlace(
      const Place(id: 'late-place', name: 'A location', lat: 3, lng: 4),
    );
    d.settings.setDayHours(2, 20);
    expect(d.nodes.state, isEmpty);
    expect(d.places.state, isEmpty);
    expect(d.settings.state.dayStartHour, 6);
    await tester.tapAt(tester.getCenter(find.text('Save open editor')));
    expect(edits, 0);

    final incoming = d.auth.login('b@example.com', 'password123');
    await tester.pump();
    expect(d.auth.state.isSignedIn, isFalse);
    expect(d.meta.state.lastEmail, 'a@example.com');
    storage.pauseDomainWrites = false;
    storage.paused.complete();
    await tester.pump();
    await removal;
    expect(await incoming, isTrue);
    expect(d.auth.state.email, 'b@example.com');
    expect(d.engine.accountTransitioning.value, isFalse);
    expect(d.nodes.state, isEmpty);
    expect(d.places.state, isEmpty);
    d.meta.reset();
    await d.engine.syncNow();
    expect(server.store['nodes'] ?? {}, isEmpty);
    expect(server.store['places'] ?? {}, isEmpty);

    // Isolation keeps A's offline backup intact across B's session.
    server.store.clear();
    await d.signIn();
    expect(d.nodes.byId('draft')?.title, 'A private');
    expect(d.nodes.byId('late'), isNull);
    expect(d.nodes.byId('deleted'), isNull);
    expect(d.places.state.single.id, 'home');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
