import 'package:a_fish_in_sea/sync/sync_meta_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

import '../sync/support/delayed_storage.dart';

void main() {
  setUp(() => HydratedBloc.storage = DelayedStorage());

  test('unfinished restoration round-trips its owner and offline recovery', () {
    final meta = SyncMetaCubit();
    addTearDown(meta.close);
    const pending = SyncMetaState(
      lastEmail: 'a@example.com',
      pendingRestoration: true,
      accountSnapshots: {
        'a@example.com': AccountSnapshot(
          collections: {
            'nodes': {
              'draft': {'id': 'draft', 'title': 'offline'},
            },
          },
        ),
      },
    );
    expect(meta.fromJson(meta.toJson(pending)), pending);
    meta.emit(pending);
    meta.reset();
    expect(meta.state.pendingRestoration, isTrue);
    expect(meta.state.lastEmail, pending.lastEmail);
    expect(meta.state.accountSnapshots, pending.accountSnapshots);
    meta.save(cursor: 'next');
    expect(meta.state.pendingRestoration, isTrue);
  });

  test(
    'legacy and malformed restoration markers keep valid recovery items',
    () {
      final meta = SyncMetaCubit();
      addTearDown(meta.close);
      for (final marker in [null, false, 'true', 1, <String, dynamic>{}]) {
        final restored = meta.fromJson({
          if (marker != null) 'pendingRestoration': marker,
          'lastEmail': 'a@example.com',
          'items': {
            'nodes/good': {'hash': 'h', 'serverTime': 't'},
            'nodes/bad': 'garbage',
          },
          'accountSnapshots': {
            'a@example.com': {
              'collections': {
                'nodes': {
                  'draft': {'id': 'draft', 'title': 'offline'},
                },
              },
            },
            'broken@example.com': 'invalid',
          },
        })!;
        expect(restored.pendingRestoration, isFalse);
        expect(restored.lastEmail, 'a@example.com');
        expect(restored.items.keys, ['nodes/good']);
        expect(restored.accountSnapshots.keys, ['a@example.com']);
        expect(
          restored
              .accountSnapshots['a@example.com']
              ?.collections['nodes']?['draft']?['title'],
          'offline',
        );
      }
    },
  );
}
