import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/reporting/model/place.dart';
import 'package:a_fish_in_sea/settings/view/sync_section.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

import 'support/sync_test_device.dart';

void main() {
  setUp(() {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  test('Keep recovers a lost task collection including its offline draft '
      'across subsequent sign-outs', () async {
    final server = FakeSyncClient();
    final d = SyncTestDevice(server);
    addTearDown(d.waterfall.close);
    await d.signIn();
    d.nodes.addNode(
      Node(id: 'synced', title: 'Cloud task', createdAt: DateTime(2026)),
    );
    await d.engine.syncNow();
    d.nodes.addNode(
      Node(id: 'draft', title: 'Offline draft', createdAt: DateTime(2026)),
    );
    expect(server.store['nodes'], isNot(contains('draft')));
    await d.engine.signOut();
    d.nodes.applyJson(const {'nodes': <dynamic>[]}); // Lost local store.

    await d.signIn();
    d.meta.reset(); // AuthPage resets bookkeeping after signing in.
    await d.engine.syncNow();
    expect(d.nodes.state.map((n) => n.id), containsAll(['synced', 'draft']));
    expect(server.store['nodes']!['draft']!.deleted, isFalse);

    await d.engine.signOut();
    d.nodes.applyJson(const {'nodes': <dynamic>[]});
    await d.signIn();
    d.meta.reset();
    await d.engine.syncNow();
    expect(d.nodes.state.map((n) => n.id), containsAll(['synced', 'draft']));
    expect(server.store['nodes']!.values.every((row) => !row.deleted), isTrue);
  });

  test(
    'Keep then loss of four places re-pulls without tombstoning them',
    () async {
      final server = FakeSyncClient();
      final d = SyncTestDevice(server);
      await d.signIn();
      for (var i = 0; i < 4; i++) {
        d.places.addPlace(
          Place(id: 'p$i', name: 'Place $i', lat: i.toDouble(), lng: 0),
        );
      }
      d.nodes.addNode(
        Node(id: 't1', title: 'original', createdAt: DateTime(2026)),
      );
      await d.engine.syncNow();
      await d.engine.syncNow(); // Settle beyond the pushed records' timestamps.
      await d.engine.signOut();
      d.places.applyJson(const {'places': <dynamic>[]});
      d.nodes.updateNode(d.nodes.byId('t1')!.copyWith(title: 'offline edit'));

      await d.signIn();
      d.meta.reset(); // AuthPage's post-login reset must also be safe.
      await d.engine.syncNow();

      expect(server.pullCursors.last, isNull);
      expect(d.places.state, hasLength(4));
      expect(
        server.store['places']!.values.every((row) => !row.deleted),
        isTrue,
      );
      expect(server.store['nodes']!['t1']!.data['title'], 'offline edit');
    },
  );

  testWidgets('recovery button forces a full pull with an existing snapshot', (
    tester,
  ) async {
    final server = FakeSyncClient();
    final d = SyncTestDevice(server);
    await d.signIn();
    for (var i = 0; i < 6; i++) {
      d.places.addPlace(
        Place(id: 'p$i', name: 'Place $i', lat: i.toDouble(), lng: 0),
      );
    }
    await d.engine.syncNow();
    await d.engine.syncNow();
    await d.engine.signOut();
    await d.signIn();
    d.meta.reset();
    await d.engine.syncNow();
    expect(d.meta.state.accountSnapshots, isNotEmpty);

    d.places.applyJson(const {'places': <dynamic>[]});
    await d.engine.syncNow();
    expect(d.engine.protectedDeletions.value, ['places']);
    expect(server.pullCursors.last, isNotNull);
    await tester.pumpWidget(
      RepositoryProvider<SyncEngine>.value(
        value: d.engine,
        child: const MaterialApp(home: Scaffold(body: SyncSection())),
      ),
    );
    await tester.tap(find.text('Restore missing items from cloud'));
    await tester.pumpAndSettle();

    expect(server.pullCursors.last, isNull);
    expect(d.places.state, hasLength(6));
    expect(server.store['places']!.values.every((row) => !row.deleted), isTrue);
    expect(find.text('Restore missing items from cloud'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await d.waterfall.close();
  });
}
