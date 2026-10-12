import 'dart:async';

import 'package:flutter/foundation.dart';

import '../finances/bloc/plaid_cubit.dart';
import '../finances/bloc/transactions_cubit.dart';
import '../finances/bloc/waterfall_cubit.dart';
import '../nodes/bloc/node_cubit.dart';
import '../planner/bloc/calendar_cubit.dart';
import '../planner/bloc/feed_cubit.dart';
import '../planner/bloc/settings_cubit.dart';
import '../reporting/bloc/places_cubit.dart';
import '../reporting/bloc/reporting_cubit.dart';
import '../reporting/bloc/tracking_cubit.dart';
import 'auth_cubit.dart';
import 'sync_client.dart';
import 'sync_meta_cubit.dart';

enum EngineStatus { idle, syncing, error }

/// Offline-first sync across every domain collection.
///
/// Protocol (matches server/api):
/// - pull(since=cursor) -> merge records into local cubits
/// - push local diffs (content-hash vs [SyncMetaCubit]) -> update meta
///
/// Conflict policy is item-level last-write-wins with **server wins** on
/// true conflicts (same item changed on both sides since last sync). This
/// is documented on the login screen and in server/api/README.md; undo
/// history stays local-only so a bad merge is still undoable on-device.
///
/// What is deliberately NOT synced:
/// - Undo/redo stacks (device-local by design)
/// - GPS recording flags (isRecording/startedAt — a phone records GPS; the
///   server must not remote-control that); only the points roam
/// - Settings.icalProxyBase (retired override; the app uses the one fixed
///   [ServerConfig] server, so the stale key never roams)
class SyncEngine {
  final SyncClient client;
  final AuthCubit auth;
  final SyncMetaCubit meta;

  final CalendarCubit events;
  final FeedCubit feeds;
  final NodeCubit nodes;
  final TransactionsCubit transactions;
  final PlacesCubit places;
  final ReportingCubit reporting;
  final TrackingCubit tracking;
  final SettingsCubit settings;
  final WaterfallCubit waterfall;
  final PlaidCubit plaid;

  final ValueNotifier<EngineStatus> status =
      ValueNotifier(EngineStatus.idle);
  String? lastError;
  DateTime? lastSyncAt;

  /// Collections whose pending deletions were withheld by the
  /// mass-deletion guard on the last sync ([_looksLikeDataLoss]). Shown in
  /// Settings → Sync; a "restore from cloud" clears the sync bookkeeping so
  /// the next pull re-downloads the items onto this device.
  final ValueNotifier<List<String>> protectedDeletions =
      ValueNotifier(const []);

  Timer? _timer;
  bool _running = false;

  SyncEngine({
    required this.client,
    required this.auth,
    required this.meta,
    required this.events,
    required this.feeds,
    required this.nodes,
    required this.transactions,
    required this.places,
    required this.reporting,
    required this.tracking,
    required this.settings,
    required this.waterfall,
    required this.plaid,
  });

  static const List<String> collections = [
    'nodes',
    'events',
    'feeds',
    'transactions',
    'places',
    'reported_entries',
    'tracked_points',
    'settings',
    'waterfall',
    'plaid',
  ];

  /// Boot: one sync if signed in. Call once from the widget tree.
  Future<void> boot() async {
    if (auth.state.isSignedIn) {
      await syncNow();
    }
  }

  void startAutoSync({Duration interval = const Duration(minutes: 5)}) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) {
      if (auth.state.isSignedIn) syncNow();
    });
  }

  void stopAutoSync() {
    _timer?.cancel();
    _timer = null;
  }

  /// Full pull-then-push. Reentrant calls collapse into the running one.
  Future<void> syncNow() async {
    if (_running) return;
    if (!auth.state.isSignedIn) return;
    _running = true;
    status.value = EngineStatus.syncing;
    try {
      final pull =
          await client.pull(since: meta.state.cursor, collections: collections);
      _applyPull(pull.changes);
      await _pushDiffs();
      if (pull.serverTime.isNotEmpty) {
        meta.save(cursor: pull.serverTime);
      }
      lastSyncAt = DateTime.now();
      lastError = null;
      status.value = EngineStatus.idle;
    } on SyncException catch (e) {
      lastError = e.message;
      status.value = EngineStatus.error;
    } catch (e) {
      lastError = e.toString();
      status.value = EngineStatus.error;
    } finally {
      _running = false;
    }
  }

  // ── Extract (cubit -> {itemId: data}) ────────────────────────────────

  Map<String, Map<String, dynamic>> _extract(String collection) {
    List<dynamic> listOf(Map<String, dynamic>? env, String key) {
      final l = env?[key];
      return l is List ? l : const [];
    }

    Map<String, dynamic> asMap(dynamic e) =>
        Map<String, dynamic>.from(e as Map);

    Map<String, Map<String, dynamic>> idMap(List<dynamic> list) => {
          for (final e in list)
            if (asMap(e)['id'] is String)
              (asMap(e)['id'] as String): asMap(e)
        };

    switch (collection) {
      case 'nodes':
        return idMap(listOf(nodes.toJson(nodes.state), 'nodes'));
      case 'events':
        return idMap(listOf(events.toJson(events.state), 'events'));
      case 'feeds':
        return idMap(listOf(feeds.toJson(feeds.state), 'feeds'));
      case 'transactions':
        return idMap(
            listOf(transactions.toJson(transactions.state), 'transactions'));
      case 'places':
        return idMap(listOf(places.toJson(places.state), 'places'));
      case 'reported_entries': {
        final days = reporting.toJson(reporting.state)['days'];
        final out = <String, Map<String, dynamic>>{};
        if (days is Map) {
          for (final entry in days.entries) {
            final day = entry.key.toString();
            final items = entry.value is List ? entry.value as List : const [];
            out[day] = {
              'day': day,
              'entries': [
                for (final e in items) Map<String, dynamic>.from(e as Map)
              ],
            };
          }
        }
        return out;
      }
      case 'tracked_points': {
        return idMap(
            listOf(tracking.toJson(tracking.state), 'points'));
      }
      case 'settings': {
        final env = Map<String, dynamic>.from(settings.toJson(settings.state));
        env.remove('icalProxyBase'); // retired override, never roams
        return {'singleton': env};
      }
      case 'waterfall': {
        final env = waterfall.toJson(waterfall.state);
        return {
          'singleton':
              env == null ? <String, dynamic>{} : Map<String, dynamic>.from(env)
        };
      }
      case 'plaid': {
        final env = plaid.toJson(plaid.state);
        return {
          'singleton':
              env == null ? <String, dynamic>{} : Map<String, dynamic>.from(env)
        };
      }
    }
    return {};
  }

  // ── Apply pull ──────────────────────────────────────────────────────

  void _applyPull(List<SyncRecord> records) {
    final byCollection = <String, List<SyncRecord>>{};
    for (final r in records) {
      (byCollection[r.collection] ??= []).add(r);
    }
    final upsertMeta = <String, ItemMeta>{};
    final removeMeta = <String>{};
    for (final entry in byCollection.entries) {
      final collection = entry.key;
      if (!collections.contains(collection)) continue;
      final current = _extract(collection);
      var changed = false;
      for (final r in entry.value) {
        final k = SyncMetaCubit.key(collection, r.itemId);
        final m = meta.state.items[k];
        final seen = _stamp(r.updatedAt);
        if (r.deleted) {
          if (current.remove(r.itemId) != null) changed = true;
          removeMeta.add(k);
          continue;
        }
        if (m == null) {
          final merged = Map<String, dynamic>.from(r.data);
          // Fresh bookkeeping (new device, reset meta): same rule as a
          // conflict — a locally running timer is live truth, not stale.
          _preserveRunningTimer(collection, current[r.itemId], merged);
          current[r.itemId] = merged;
          changed = true;
          upsertMeta[k] = ItemMeta(
              hash: contentHash(merged), serverTime: seen);
          continue;
        }
        if (m.serverTime == seen) {
          continue; // remote unchanged; local diff handled at push
        }
        // Remote changed. No local change -> take server; local change
        // too -> conflict, server wins (documented policy). Both adopt
        // the merged copy; the running-timer carve-out inside
        // [_preserveRunningTimer] is the only way local state survives
        // a pull. When the merge resolves to the local copy (e.g. it
        // kept an earlier timer start), the meta is left alone so the
        // push phase propagates the merged version back to the server.
        final local = current[r.itemId];
        final merged = Map<String, dynamic>.from(r.data);
        _preserveRunningTimer(collection, local, merged);
        if (local == null || contentHash(merged) != contentHash(local)) {
          current[r.itemId] = merged;
          changed = true;
          upsertMeta[k] = ItemMeta(
              hash: contentHash(merged), serverTime: seen);
        }
      }
      if (changed) _apply(collection, current);
    }
    if (upsertMeta.isNotEmpty || removeMeta.isNotEmpty) {
      meta.save(upsert: upsertMeta, remove: removeMeta);
    }
  }

  static String _stamp(DateTime t) => t.toUtc().toIso8601String();

  /// A running timer is wall-clock truth, not last-write-wins data: taking
  /// a server copy verbatim would silently stop a timer the user started
  /// (e.g. a boot sync pulling the pre-start version after a rebuild).
  /// When the local copy is recording, its start survives the merge; when
  /// both sides record, the earliest start wins (the true start). A remote
  /// stop still lands its reported interval — only the live start is kept.
  ///
  /// One exception: the remote record stopped *after* the local run
  /// started ([actualEnd] later than the local start). That stop targets
  /// this run (e.g. stopped on another device), so it wins and the local
  /// timer clears. Older remote actuals predate the run — a previous
  /// session — and never stop it.
  static void _preserveRunningTimer(String collection,
      Map<String, dynamic>? local, Map<String, dynamic> merged) {
    if (collection != 'nodes' && collection != 'events') return;
    final localStart = local?['timerStartedAt'];
    if (localStart is! String || localStart.isEmpty) return;
    final localDt = DateTime.tryParse(localStart);
    if (localDt == null) return;
    final remoteStart = merged['timerStartedAt'];
    final remoteDt =
        remoteStart is String && remoteStart.isNotEmpty
            ? DateTime.tryParse(remoteStart)
            : null;
    // Both running: the earliest start is the true one (ISO strings alone
    // are not safe to compare across local/UTC forms, so compare parsed
    // instants).
    if (remoteDt != null) {
      if (localDt.isBefore(remoteDt)) {
        merged['timerStartedAt'] = localStart;
      }
      return;
    }
    final remoteEndRaw = merged['actualEnd'];
    final remoteEnd =
        remoteEndRaw is String && remoteEndRaw.isNotEmpty
            ? DateTime.tryParse(remoteEndRaw)
            : null;
    if (remoteEnd == null || !remoteEnd.isAfter(localDt)) {
      merged['timerStartedAt'] = localStart;
    }
  }

  // ── Apply merged maps back into cubits (no undo records) ────────────

  void _apply(String collection, Map<String, Map<String, dynamic>> items) {
    switch (collection) {
      case 'nodes':
        nodes.applyJson({
          'nodes': items.values.toList(),
        });
        break;
      case 'events':
        events.applyJson({
          'events': items.values.toList(),
        });
        break;
      case 'feeds':
        feeds.applyJson({
          'feeds': items.values.toList(),
        });
        break;
      case 'transactions':
        transactions.applySyncedJson({
          'transactions': items.values.toList(),
        });
        break;
      case 'places':
        places.applyJson({
          'places': items.values.toList(),
        });
        break;
      case 'reported_entries':
        reporting.applyJson({
          'days': {
            for (final e in items.entries) e.key: e.value['entries'],
          },
        });
        break;
      case 'tracked_points':
        tracking.applySyncedPoints(items.values.toList());
        break;
      case 'settings':
        final data = items['singleton'];
        if (data != null) settings.applySyncedJson(data);
        break;
      case 'waterfall':
        final data = items['singleton'];
        if (data != null) waterfall.applySyncedConfig(data);
        break;
      case 'plaid':
        final data = items['singleton'];
        if (data != null) plaid.applySyncedIdentity(data);
        break;
    }
  }

  // ── Push diffs ──────────────────────────────────────────────────────

  /// Guard thresholds. A device that lost its local store (hydrate failure,
  /// evicted browser storage, cleared app data) but kept its sync
  /// bookkeeping would otherwise tell the server "delete everything" — which
  /// then propagates the loss to every other device. Ordinary cleanup
  /// through the UI deletes a handful of items, far below these thresholds.
  ///
  /// - Large collection: >= 100 pending deletes AND >= 20% of everything
  ///   tracked for that collection in one sync.
  /// - Small collection: >= 5 pending deletes AND >= 90% of everything
  ///   tracked (e.g. all feeds removed at once without the loss being real
  ///   is much more likely a wipe than intent).
  static const int _guardLargeMinItems = 100;
  static const int _guardSmallMinItems = 5;

  static bool _looksLikeDataLoss(int pendingDeletes, int trackedCount) {
    if (trackedCount <= 0 || pendingDeletes <= 0) return false;
    if (pendingDeletes >= _guardLargeMinItems &&
        pendingDeletes * 5 >= trackedCount) {
      return true;
    }
    if (pendingDeletes >= _guardSmallMinItems &&
        pendingDeletes * 10 >= trackedCount * 9) {
      return true;
    }
    return false;
  }

  Future<void> _pushDiffs() async {
    // Group bookkeeping keys per collection so the guard can weigh a
    // collection's pending deletions against everything it tracks.
    final metaByCollection = <String, List<String>>{};
    for (final k in meta.state.items.keys) {
      final slash = k.indexOf('/');
      if (slash <= 0) continue;
      (metaByCollection[k.substring(0, slash)] ??= []).add(
        k.substring(slash + 1),
      );
    }

    final changes = <Map<String, dynamic>>[];
    var guarded = <String>[];
    for (final collection in collections) {
      final current = _extract(collection);
      for (final entry in current.entries) {
        final k = SyncMetaCubit.key(collection, entry.key);
        final m = meta.state.items[k];
        if (m == null || m.hash != contentHash(entry.value)) {
          changes.add({
            'collection': collection,
            'item_id': entry.key,
            'data': entry.value,
            'deleted': false,
          });
        }
      }
      final metaIds = metaByCollection[collection] ?? const <String>[];
      final missing = <String>[
        for (final id in metaIds)
          if (!current.containsKey(id)) id,
      ];
      if (_looksLikeDataLoss(missing.length, metaIds.length)) {
        // Keep local meta untouched: the items stay on the server (and on
        // every other device) instead of being deleted farm-wide.
        guarded.add(collection);
      } else {
        for (final id in missing) {
          changes.add({
            'collection': collection,
            'item_id': id,
            'data': const {},
            'deleted': true,
          });
        }
      }
    }
    if (guarded.isNotEmpty) {
      debugPrint(
        '[sync] withheld mass deletion for $guarded — local data looks '
        'lost; cloud copy kept (see Settings → Sync)',
      );
    }
    // 'settings'/'waterfall'/'plaid' singletons always exist locally:
    // never push tombstones for them.
    changes.removeWhere((c) =>
        c['deleted'] == true &&
        (c['item_id'] == 'singleton' ||
            (c['collection'] == 'tracked_points' &&
                (c['item_id'] as String).isEmpty)));
    if (changes.isEmpty) {
      protectedDeletions.value = guarded;
      return;
    }
    final pushed = await client.push(changes);
    final applied = pushed.applied;
    if (pushed.guarded.isNotEmpty) {
      debugPrint(
        '[sync] server withheld mass deletion for ${pushed.guarded} — '
        'cloud copy kept (see Settings → Sync)',
      );
      guarded = {...guarded, ...pushed.guarded}.toList();
    }
    protectedDeletions.value = guarded;
    final upsertMeta = <String, ItemMeta>{};
    final removeMeta = <String>{};
    for (final r in applied) {
      final k = SyncMetaCubit.key(r.collection, r.itemId);
      if (r.deleted) {
        removeMeta.add(k);
      } else {
        upsertMeta[k] = ItemMeta(
            hash: contentHash(r.data), serverTime: _stamp(r.updatedAt));
      }
    }
    meta.save(upsert: upsertMeta, remove: removeMeta);
  }
}
