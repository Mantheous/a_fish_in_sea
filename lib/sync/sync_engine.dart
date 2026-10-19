import 'dart:async';

import 'package:flutter/foundation.dart';

import '../demo/demo_mode.dart';
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
import 'sync_timer_merge.dart';

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
/// - Settings.ankiConnectHost (per-device like the proxy above: a desktop
///   talks to its own localhost, a phone to a LAN address — roaming one
///   value would break the other device, so each device keeps its own)
/// - Settings.defaultCalendarView (a phone wants day, a desktop wants week;
///   roaming one value would reset the other device's visible window, so
///   each device keeps its own — day hours still roam)
/// - Plaid wasConnected (connectivity is derived on-device; only the link
///   identity — userId/itemId — roams, so a disconnect reaches every device
///   instead of flapping back)
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
  int _epoch = 0;

  /// Change-triggered sync: debounced [syncNow] after a local mutation, so
  /// edits (starting/completing a task or event) reach the server without
  /// waiting for the 5-minute timer. Pull-applied records must not retrigger
  /// it — [_applyingRemote] fences those emissions out.
  final List<StreamSubscription<void>> _mutationSubs = [];
  Timer? _mutationDebounce;
  bool _applyingRemote = false;
  Duration mutationDebounce = const Duration(seconds: 2);

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

  /// Watches every synced domain cubit and schedules a debounced [syncNow]
  /// on local mutations. Remote pulls never retrigger it ([_applyingRemote]),
  /// so a pull settles instead of ping-ponging. Safe to call twice.
  void startAutoSyncOnChanges({Duration? debounce}) {
    if (debounce != null) mutationDebounce = debounce;
    stopAutoSyncOnChanges();
    void watch(Stream<dynamic> states) {
      _mutationSubs.add(states.listen((_) => _onLocalMutation()));
    }

    watch(nodes.stream);
    watch(events.stream);
    watch(feeds.stream);
    watch(transactions.stream);
    watch(places.stream);
    watch(reporting.stream);
    watch(tracking.stream);
    watch(settings.stream);
    watch(waterfall.stream);
    watch(plaid.stream);
  }

  void _onLocalMutation() {
    if (_applyingRemote) return;
    if (!auth.state.isSignedIn) return;
    if (DemoMode.isActive) return;
    _mutationDebounce?.cancel();
    _mutationDebounce = Timer(mutationDebounce, () {
      if (auth.state.isSignedIn) syncNow();
    });
  }

  void stopAutoSyncOnChanges() {
    for (final sub in _mutationSubs) {
      unawaited(sub.cancel());
    }
    _mutationSubs.clear();
    _mutationDebounce?.cancel();
    _mutationDebounce = null;
  }

  /// Clears all local domain cubits and bank session state. Used on sign-out
  /// and when switching to a different account so one user's local data can
  /// never be merged/pushed into another user's cloud account.
  void clearLocalAccountData() {
    nodes.applyJson(const {'nodes': <dynamic>[]});
    events.applyJson(const {'events': <dynamic>[]});
    feeds.applyJson(const {'feeds': <dynamic>[]});
    transactions.applySyncedJson(const {'transactions': <dynamic>[]});
    places.applyJson(const {'places': <dynamic>[]});
    reporting.applyJson(const {'days': <String, dynamic>{}});
    tracking.applySyncedPoints(const <Map<String, dynamic>>[]);
    waterfall.applySyncedConfig(const {'startingBalance': 0.0});
    plaid.clearLocalSession();
    protectedDeletions.value = const [];
  }

  Map<String, AccountSnapshot> _withSnapshotFor(String email) {
    final next = Map<String, AccountSnapshot>.of(meta.state.accountSnapshots);
    if (email.isNotEmpty) {
      final prev = next[email];
      final hasActiveMeta =
          meta.state.cursor != null || meta.state.items.isNotEmpty;
      next[email] = AccountSnapshot(
        cursor: hasActiveMeta ? meta.state.cursor : prev?.cursor,
        items: hasActiveMeta
            ? Map<String, ItemMeta>.of(meta.state.items)
            : (prev?.items ?? const {}),
        collections: {
          for (final c in collections) c: _extract(c),
        },
      );
    }
    return next;
  }

  AccountSnapshot? _restoreLocalAccountIfPresent(
    String email,
    Map<String, AccountSnapshot> snapshots,
  ) {
    final snap = snapshots[email];
    if (snap == null) return null;
    for (final entry in snap.collections.entries) {
      _apply(entry.key, entry.value);
    }
    return snap;
  }

  /// Epoch-fences any in-flight sync, revokes the session, disconnects Plaid,
  /// and records the signed-out account's email + snapshot in [SyncMetaCubit]
  /// (keeping on-device data intact by default so unsynced local work is never
  /// lost even across app restarts, while isolating it if a different account
  /// signs in next).
  void signOut({bool clearLocalData = false}) {
    _epoch++;
    _running = false;
    status.value = EngineStatus.idle;
    lastError = null;
    final previousEmail = auth.state.email.trim().toLowerCase();
    final updatedSnapshots =
        previousEmail.isNotEmpty ? _withSnapshotFor(previousEmail) : null;
    auth.logout();
    plaid.clearLocalSession();
    if (clearLocalData) {
      clearLocalAccountData();
      meta.reset(clearLastEmail: true, accountSnapshots: updatedSnapshots);
    } else {
      meta.reset(
        lastEmail:
            previousEmail.isEmpty ? meta.state.lastEmail : previousEmail,
        accountSnapshots: updatedSnapshots,
      );
    }
  }

  /// Full pull-then-push. Reentrant calls collapse into the running one.
  Future<void> syncNow() async {
    if (DemoMode.isActive) return;
    if (_running) return;
    if (!auth.state.isSignedIn) return;
    final sessionGeneration = auth.sessionGeneration;
    final currentEmail = auth.state.email.trim().toLowerCase();
    final prevEmail = meta.state.lastEmail?.trim().toLowerCase();
    if (prevEmail != null &&
        prevEmail.isNotEmpty &&
        currentEmail.isNotEmpty &&
        prevEmail != currentEmail) {
      final updatedSnapshots = _withSnapshotFor(prevEmail);
      clearLocalAccountData();
      final restored =
          _restoreLocalAccountIfPresent(currentEmail, updatedSnapshots);
      meta.reset(
        clearLastEmail: true,
        lastEmail: currentEmail,
        cursor: restored?.cursor,
        items: restored?.items,
        accountSnapshots: updatedSnapshots,
      );
    } else if (currentEmail.isNotEmpty) {
      final restored = meta.state.accountSnapshots[currentEmail];
      if (meta.state.cursor == null &&
          meta.state.items.isEmpty &&
          restored != null &&
          (restored.cursor != null || restored.items.isNotEmpty)) {
        // Returning to a previously-synced account with no active baseline
        // (e.g. after app restart): reseed its item meta so the normal pull
        // conflict path runs instead of overwriting local edits. Live cubits
        // stay authoritative for the same account — only backfill
        // collections that are currently empty (e.g. storage was evicted),
        // never overwrite live data with the sign-out-time snapshot.
        for (final entry in restored.collections.entries) {
          if (_extract(entry.key).isEmpty && entry.value.isNotEmpty) {
            _apply(entry.key, entry.value);
          }
        }
        meta.save(
          cursor: restored.cursor,
          upsert: restored.items,
          lastEmail: currentEmail,
        );
      } else if (prevEmail != currentEmail) {
        meta.save(lastEmail: currentEmail);
      }
    }
    final myEpoch = ++_epoch;
    _running = true;
    status.value = EngineStatus.syncing;
    try {
      final pull =
          await client.pull(since: meta.state.cursor, collections: collections);
      if (!_isCurrentSession(myEpoch, sessionGeneration)) return;
      _applyPull(pull.changes);
      await _pushDiffs(myEpoch, sessionGeneration);
      if (!_isCurrentSession(myEpoch, sessionGeneration)) return;
      if (pull.serverTime.isNotEmpty) {
        meta.save(
          cursor: pull.serverTime,
          lastEmail: currentEmail.isEmpty ? null : currentEmail,
        );
      }
      lastSyncAt = DateTime.now();
      lastError = null;
      status.value = EngineStatus.idle;
    } on SyncException catch (e) {
      if (_isCurrentSession(myEpoch, sessionGeneration)) {
        lastError = e.message;
        status.value = EngineStatus.error;
      }
    } catch (e) {
      if (_isCurrentSession(myEpoch, sessionGeneration)) {
        lastError = e.toString();
        status.value = EngineStatus.error;
      }
    } finally {
      if (_epoch == myEpoch) {
        _running = false;
        if (!auth.state.isSignedIn ||
            auth.sessionGeneration != sessionGeneration) {
          status.value = EngineStatus.idle;
        }
      }
    }
  }

  bool _isCurrentSession(int epoch, int sessionGeneration) =>
      _epoch == epoch &&
      auth.sessionGeneration == sessionGeneration &&
      auth.state.isSignedIn;

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
        _stripDeviceLocalFields('settings', env);
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
        final map =
            env == null ? <String, dynamic>{} : Map<String, dynamic>.from(env);
        _stripDeviceLocalFields('plaid', map);
        return {'singleton': map};
      }
    }
    return {};
  }

  static void _stripDeviceLocalFields(
      String collection, Map<String, dynamic> data) {
    if (collection == 'settings') {
      data.remove('icalProxyBase');
      data.remove('ankiConnectHost');
      data.remove('defaultCalendarView');
    } else if (collection == 'plaid') {
      data.remove('wasConnected');
    }
  }

  // ── Apply pull ──────────────────────────────────────────────────────

  void _applyPull(List<SyncRecord> records) {
    _applyingRemote = true;
    try {
      _applyPullRecords(records);
    } finally {
      _applyingRemote = false;
    }
  }

  void _applyPullRecords(List<SyncRecord> records) {
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
        final seen = syncRecordStamp(r.updatedAt);
        if (r.deleted) {
          if (current.remove(r.itemId) != null) changed = true;
          removeMeta.add(k);
          continue;
        }
        if (m == null) {
          final merged = Map<String, dynamic>.from(r.data);
          _stripDeviceLocalFields(collection, merged);
          // Fresh bookkeeping (new device, reset meta): same rule as a
          // conflict — a locally running timer is live truth, not stale.
          preserveRunningTimer(collection, current[r.itemId], merged);
          current[r.itemId] = merged;
          changed = true;
          upsertMeta[k] = ItemMeta(
              hash: contentHash(r.data), serverTime: seen);
          continue;
        }
        if (m.serverTime == seen) {
          continue; // remote unchanged; local diff handled at push
        }
        // Remote changed. No local change -> take server; local change
        // too -> conflict, server wins (documented policy). Both adopt
        // the merged copy; the running-timer carve-out inside
        // [preserveRunningTimer] is the only way local state survives
        // a pull. When the merge resolves to the local copy (e.g. it
        // kept an earlier timer start), the meta is left alone so the
        // push phase propagates the merged version back to the server.
        final local = current[r.itemId];
        final merged = Map<String, dynamic>.from(r.data);
        _stripDeviceLocalFields(collection, merged);
        preserveRunningTimer(collection, local, merged);
        upsertMeta[k] = ItemMeta(
          hash: contentHash(r.data),
          serverTime: seen,
        );
        if (local == null || contentHash(merged) != contentHash(local)) {
          current[r.itemId] = merged;
          changed = true;
        }
      }
      if (changed) {
        _apply(collection, current);
      }
    }
    // Undo replay is item-scoped (only the ids the user's edit touched),
    // so history safely survives a pull: pulled ids are never in any
    // record's changed set, and the next push sends no tombstones for them.
    if (upsertMeta.isNotEmpty || removeMeta.isNotEmpty) {
      meta.save(upsert: upsertMeta, remove: removeMeta);
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

  Future<void> _pushDiffs(int myEpoch, int sessionGeneration) async {
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
    if (!_isCurrentSession(myEpoch, sessionGeneration)) return;
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
            hash: contentHash(r.data),
            serverTime: syncRecordStamp(r.updatedAt));
      }
    }
    meta.save(upsert: upsertMeta, remove: removeMeta);
  }
}
