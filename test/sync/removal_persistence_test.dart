import 'package:a_fish_in_sea/sync/sync_meta_cubit.dart';
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

  test('pending removal round-trips ownership and unsynced recovery', () {
    final meta = SyncMetaCubit();
    const pending = SyncMetaState(
      lastEmail: 'a@example.com',
      pendingRemoval: true,
      accountSnapshots: {
        'a@example.com': AccountSnapshot(
          collections: {
            'nodes': {
              'offline': {'id': 'offline', 'title': 'draft'},
            },
          },
        ),
      },
    );
    expect(meta.fromJson(meta.toJson(pending)), pending);
    meta.emit(pending);
    meta.reset(); // Login must preserve the interrupted-removal marker.
    expect(meta.state.pendingRemoval, isTrue);
    expect(meta.state.lastEmail, 'a@example.com');
    expect(meta.state.accountSnapshots, pending.accountSnapshots);
  });

  test('legacy and malformed removal markers preserve valid item metadata', () {
    final meta = SyncMetaCubit();
    for (final marker in [null, false, 'true', 1, <String, dynamic>{}]) {
      final restored = meta.fromJson({
        if (marker != null) 'pendingRemoval': marker,
        'lastEmail': 'a@example.com',
        'items': {
          'nodes/good': {'hash': 'h', 'serverTime': 't'},
          'nodes/bad': 'garbage',
        },
      })!;
      expect(restored.pendingRemoval, isFalse);
      expect(restored.lastEmail, 'a@example.com');
      expect(restored.items.keys, ['nodes/good']);
    }
  });
}
