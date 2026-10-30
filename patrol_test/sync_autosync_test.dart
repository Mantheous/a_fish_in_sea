import 'package:a_fish_in_sea/main.dart';
import 'package:a_fish_in_sea/navigation/view/home_page.dart';
import 'package:a_fish_in_sea/nodes/bloc/node_cubit.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/planner/bloc/calendar_cubit.dart';
import 'package:a_fish_in_sea/planner/model/planner_event.dart';
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
  patrolTest('auto-sync sends edits and keeps remote recordings deleted', ($) async {
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

    // refs #239: this app is device B; direct API writes represent device A.
    // Freeze background sync so A -> B -> A ordering is deterministic.
    engine.stopAutoSyncOnChanges();
    engine.stopAutoSync();
    final client = engine.client;
    final events = context.read<CalendarCubit>();
    final id = 'patrol-recording-$stamp';
    final start = DateTime(2026, 10, 20, 9);
    nodes.addNode(Node(id: id, title: 'Recorded task', createdAt: start));
    events.addEvent(
      PlannerEvent(
        id: id,
        subject: 'Recorded event',
        start: start,
        end: start.add(const Duration(hours: 1)),
      ),
    );
    for (final offset in [0, 60]) {
      final run = start.add(Duration(minutes: offset));
      nodes.addSession(id, run, run.add(const Duration(minutes: 20)));
      events.addSession(id, run, run.add(const Duration(minutes: 20)));
    }
    await engine.syncNow();
    expect(engine.status.value, EngineStatus.idle);

    // Delete one run, then the final run. After each A -> B -> A round trip,
    // neither device B nor the server may resurrect the removed recording.
    for (final remaining in [1, 0]) {
      final shared = await client.pull(collections: ['nodes', 'events']);
      final records = shared.changes.where((r) => r.itemId == id).toList();
      expect(records, hasLength(2));
      await client.push([
        for (final record in records)
          {
            'collection': record.collection,
            'item_id': id,
            'deleted': false,
            'data': {
              ...record.data,
              'sessions': (record.data['sessions'] as List)
                  .take(remaining)
                  .toList(),
              'actualStart': remaining == 0
                  ? null
                  : start.toUtc().toIso8601String(),
              'actualEnd': remaining == 0
                  ? null
                  : start
                        .add(const Duration(minutes: 20))
                        .toUtc()
                        .toIso8601String(),
            },
          },
      ]);
      await engine.syncNow();
      expect(engine.status.value, EngineStatus.idle);
      expect(nodes.byId(id)!.recordedSessions, hasLength(remaining));
      expect(events.byId(id)!.recordedSessions, hasLength(remaining));
      final onA = await client.pull(collections: ['nodes', 'events']);
      for (final record in onA.changes.where((r) => r.itemId == id)) {
        expect(record.data['sessions'], hasLength(remaining));
        if (remaining == 0) {
          expect(record.data['actualStart'], isNull);
          expect(record.data['actualEnd'], isNull);
        }
      }
    }
  });
}
