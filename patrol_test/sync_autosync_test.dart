import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/sync/sync_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:patrol/patrol.dart';

class MockStorage extends Mock implements Storage {}

/// refs #50: a local edit (new task) must reach the server on its own via
/// the debounced change-triggered sync — no waiting for the 5-minute timer,
/// no manual "Sync now" tap.
///
/// Run against the live dev API server:
///   patrol test --device chrome --web-headless \
///     --target patrol_test/sync_autosync_test.dart \
///     --dart-define=SERVER_URL=http://127.0.0.1:8000
///
/// Uses a unique email per run so reruns never 409.
void main() {
  patrolTest('local edit auto-syncs without the timer', ($) async {
    final storage = MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    when(() => storage.clear()).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    await $.pumpWidgetAndSettle(const MyApp());
    expect($('Sign in to sync').visible, true);

    final stamp = DateTime.now().millisecondsSinceEpoch;
    await $(TextField).at(0).enterText('patrol-sync-$stamp@example.com');
    await $(TextField).at(1).enterText('patrol-pass-1');
    await $('Create account').tap();
    await $.pumpAndSettle();

    expect(find.byType(HomePage), findsOneWidget);
    final context = $.tester.element(find.byType(HomePage));
    final engine = context.read<SyncEngine>();
    final nodes = context.read<NodeCubit>();

    // The register flow ends with a sync; that is our baseline.
    expect(engine.lastSyncAt, isNotNull);
    final before = engine.lastSyncAt!;

    nodes.addNode(Node(
      id: 'patrol-task-$stamp',
      title: 'Patrol autosync task',
      createdAt: DateTime(2026),
    ));

    // Debounce (2s) + localhost round trip, with headroom. No taps here:
    // if the change-triggered sync regresses, lastSyncAt never advances.
    await Future.delayed(const Duration(seconds: 6));
    await $.pumpAndSettle();

    expect(engine.status.value, EngineStatus.idle);
    expect(engine.lastSyncAt, isNotNull);
    expect(engine.lastSyncAt!.isAfter(before), isTrue);
  });
}
