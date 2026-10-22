import 'dart:async';

import 'package:a_fish_in_sea/imports/import_service.dart';
import 'package:a_fish_in_sea/imports/view/import_review_screen.dart';
import 'package:a_fish_in_sea/sync/auth_cubit.dart';
import 'package:a_fish_in_sea/sync/sync_client.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockStorage extends Mock implements Storage {}

class MockSyncEngine extends Mock implements SyncEngine {}

/// Never touches the network; the test controls approve responses and can
/// hold them open with [gate] to observe the busy state.
class _StubSyncClient extends SyncClient {
  int postCount = 0;
  Completer<void>? gate;
  late Map<String, dynamic> Function() nextResponse;

  _StubSyncClient()
      : super(
          serverBase: () => 'http://localhost:8000',
          accessToken: () => 'tok',
          refreshAccessToken: () async => 'tok',
        );

  @override
  Future<dynamic> apiPost(String path, Map<String, dynamic> body) async {
    postCount++;
    final held = gate;
    if (held != null) await held.future;
    return nextResponse();
  }
}

Map<String, dynamic> _item(
  String id, {
  String status = 'pending',
  String due = '2026-10-17T23:59:00',
  Map<String, dynamic>? existing,
  bool existingDeleted = false,
}) =>
    {
      'collection': 'nodes',
      'item_id': id,
      'data': {
        'id': id,
        'title': 'Task $id',
        'schedule': {'due': due},
      },
      'status': status,
      if (existing != null) 'existing': existing,
      'existing_deleted': existingDeleted,
    };

Map<String, dynamic> _live(String id, String due) => {
      'id': id,
      'title': 'Task $id',
      'schedule': {'due': due},
    };

Map<String, dynamic> _batch(List<Map<String, dynamic>> items) => {
      'id': 7,
      'source': 'Email forward',
      'status': 'pending',
      'created_at': '2026-10-11T10:00:00Z',
      'items': items,
    };

/// The pending row collides with a live row, so the review shows an
/// "updates existing" warning for it.
ImportBatch _initialBatch() => ImportBatch.fromJson(_batch([
      _item('fresh'),
      _item('collide', existing: _live('collide', '2026-10-15T23:59:00')),
    ]));

/// Simulates a server response that decided [decidedId] but dropped the
/// conflict context for every other row.
Map<String, dynamic> _serverDropsWarnings(String decidedId) => _batch([
      _item('fresh',
          status: decidedId == 'fresh' ? 'approved' : 'pending'),
      _item('collide',
          status: decidedId == 'collide' ? 'approved' : 'pending'),
    ]);

Finder get _approveButtons =>
    find.widgetWithIcon(IconButton, Icons.check);
Finder get _discardButtons =>
    find.widgetWithIcon(IconButton, Icons.close);

Future<_StubSyncClient> _pump(
  WidgetTester tester,
  _StubSyncClient stub,
  MockSyncEngine engine,
) async {
  when(() => engine.syncNow()).thenAnswer((_) async {});
  await tester.pumpWidget(
    RepositoryProvider<SyncEngine>.value(
      value: engine,
      child: BlocProvider<AuthCubit>(
        create: (_) => AuthCubit(client: () => stub),
        child:
            MaterialApp(home: ImportReviewScreen(batch: _initialBatch())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return stub;
}

void main() {
  late MockStorage storage;

  setUp(() {
    storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  testWidgets(
      'approving one row keeps the update warning on the remaining row',
      (tester) async {
    final stub = _StubSyncClient()
      ..nextResponse = () => _serverDropsWarnings('fresh');
    await _pump(tester, stub, MockSyncEngine());

    // Sanity: the collision warning renders before any decision.
    expect(find.textContaining('Updates existing'), findsOneWidget);

    await tester.tap(_approveButtons.first);
    await tester.pumpAndSettle();

    expect(stub.postCount, 1);
    // The decided row flips to its done chip...
    expect(find.text('Added'), findsOneWidget);
    // ...but the untouched row keeps its warning even though the server
    // response carried no conflict context for it.
    expect(find.textContaining('Updates existing'), findsOneWidget);
    expect(find.textContaining('didn\u2019t go through'), findsNothing);
  });

  testWidgets('row buttons disable while busy and double taps fire once',
      (tester) async {
    final stub = _StubSyncClient()
      ..gate = Completer<void>()
      ..nextResponse = () => _serverDropsWarnings('fresh');
    await _pump(tester, stub, MockSyncEngine());

    await tester.tap(_approveButtons.first);
    await tester.pump();

    // Every per-row button is disabled while the decision is in flight.
    for (final finder in [_approveButtons, _discardButtons]) {
      final buttons = tester.widgetList<IconButton>(finder);
      expect(buttons, hasLength(2));
      for (final b in buttons) {
        expect(b.onPressed, isNull);
      }
    }

    // A second tap before the rebuild/finish fires nothing new.
    await tester.tap(_approveButtons.first);
    stub.gate!.complete();
    await tester.pumpAndSettle();

    expect(stub.postCount, 1);
    expect(find.textContaining('didn\u2019t go through'), findsNothing);
  });
}
