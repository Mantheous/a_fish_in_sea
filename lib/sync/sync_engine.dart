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
          current[r.itemId] = Map<String, dynamic>.from(r.data);
          changed = true;
        } else if (m.serverTime == seen) {
          continue; // remote unchanged; local diff handled at push
        } else {
          // Remote changed. No local change -> take server; local change
          // too -> conflict, server wins (documented policy).
          final local = current[r.itemId];
          if (local == null || contentHash(local) != m.hash) {
            current[r.itemId] = Map<String, dynamic>.from(r.data);
            changed = true;
          }
        }
        upsertMeta[k] = ItemMeta(
            hash: contentHash(
                Map<String, dynamic>.from(current[r.itemId] ?? r.data)),
            serverTime: seen);
      }
      if (changed) _apply(collection, current);
    }
    if (upsertMeta.isNotEmpty || removeMeta.isNotEmpty) {
      meta.save(upsert: upsertMeta, remove: removeMeta);
    }
  }

  static String _stamp(DateTime t) => t.toUtc().toIso8601String();

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

  Future<void> _pushDiffs() async {
    final changes = <Map<String, dynamic>>[];
    final metaKeys = meta.state.items.keys;
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
      for (final k in metaKeys) {
        if (!k.startsWith('$collection/')) continue;
        final id = k.substring(collection.length + 1);
        if (!current.containsKey(id)) {
          changes.add({
            'collection': collection,
            'item_id': id,
            'data': const {},
            'deleted': true,
          });
        }
      }
    }
    // 'settings'/'waterfall'/'plaid' singletons always exist locally:
    // never push tombstones for them.
    changes.removeWhere((c) =>
        c['deleted'] == true &&
        (c['item_id'] == 'singleton' ||
            (c['collection'] == 'tracked_points' &&
                (c['item_id'] as String).isEmpty)));
    if (changes.isEmpty) return;
    final applied = await client.push(changes);
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
