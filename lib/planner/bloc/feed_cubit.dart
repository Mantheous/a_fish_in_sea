import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../common/persistence/stable_storage_keys.dart';
import '../../common/undo/change_record.dart';
import '../../common/undo/revertable_hydrated_cubit.dart';
import '../../common/undo/undo_cubit.dart';
import '../../demo/demo_data.dart';
import '../../demo/demo_mode.dart';
import '../../nodes/bloc/node_cubit.dart';
import '../../nodes/model/node.dart';
import '../../nodes/service/node_feed.dart';
import '../../sync/sync_client.dart';
import '../model/assignment_rule.dart';
import 'assignment_estimates_cubit.dart';
import '../model/feed.dart';
import '../model/planner_event.dart';
import '../service/canvas_service.dart';
import '../service/feed_event_merge.dart';
import '../service/google_calendar_service.dart';
import '../service/ical_service.dart';
import 'calendar_cubit.dart';

part 'feed_sync.dart';

/// One feed's pending status change while a batched sync is running.
typedef _FeedStatusPatch = ({
  DateTime? lastSyncAt,
  bool clearError,
  String? error,
});

class FeedCubit extends RevertableHydratedCubit<List<Feed>> {
  final CalendarCubit _calendarCubit;
  final NodeCubit _nodeCubit;
  final Set<String> _pendingFeedSyncs = {};
  final IcalService _icalService;
  final GoogleCalendarService _googleService;
  final String Function() _proxyBase;

  /// Canvas submission states for auto-completing submitted homework.
  /// Null when not connected (or in tests) — sync then skips that step.
  final CanvasService? _canvasService;

  /// Sync-server client for server-side iCal snapshots. Null when signed
  /// out (or in tests) — [_syncIcal] then falls back to direct fetch.
  final SyncClient? syncClient;

  /// Current assignment rules for fresh homework imports. A provider
  /// (rather than a cubit reference) so tests can omit it; null means
  /// no shifts, exactly as before rules existed.
  final List<AssignmentRule> Function()? assignmentRulesProvider;

  /// Learned per-class time estimates, dropped for a class only when the
  /// user explicitly removes it ([removeFeed]/[removeOrphanedClass]) — and
  /// folded into that action's undo record. Null (tests, or unwired trees)
  /// means estimates are left untouched. Never touched on idle rebuilds:
  /// entering/exiting demo swaps the whole feed list, which must not wipe
  /// what the app learned about the user's real courses.
  final AssignmentEstimatesCubit? estimatesCubit;

  final ValueNotifier<bool> isSyncing = ValueNotifier(false);
  DateTime? _lastAutoSync;
  Timer? _autoResyncTimer;

  /// Exposed so the classes sheet can run the Google connect flow against
  /// the same server/user identity the sync uses.
  GoogleCalendarService get googleService => _googleService;

  /// Exposed so the classes sheet can run the Canvas token flow against
  /// the same server/user identity the sync uses. Null unless wired.
  CanvasService? get canvasService => _canvasService;

  FeedCubit({
    required CalendarCubit calendarCubit,
    required NodeCubit nodeCubit,
    required IcalService icalService,
    required GoogleCalendarService googleService,
    required String Function() proxyBase,
    this.syncClient,
    CanvasService? canvasService,
    this.assignmentRulesProvider,
    this.estimatesCubit,
  }) : _calendarCubit = calendarCubit,
       _nodeCubit = nodeCubit,
       _icalService = icalService,
       _googleService = googleService,
       _proxyBase = proxyBase,
       _canvasService = canvasService,
       super(const []);

  @override
  String get storagePrefix => StableStorageKeys.feed;

  @override
  Future<void> close() {
    _autoResyncTimer?.cancel();
    isSyncing.dispose();
    return super.close();
  }

  @override
  void invalidateAccountOperations() {
    super.invalidateAccountOperations();
    _pendingFeedSyncs.clear();
    _lastAutoSync = null;
    isSyncing.value = false;
  }

  void startAutoResync() {
    if (_autoResyncTimer != null) return;
    _autoResyncTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => syncAll(),
    );
  }

  void addFeed(Feed feed) {
    if (state.any((f) => f.id == feed.id)) {
      emitChange(state.map((f) => f.id == feed.id ? feed : f).toList());
      return;
    }
    emitChange([...state, feed]);
  }

  void updateFeed(Feed feed) =>
      emitChange(state.map((f) => f.id == feed.id ? feed : f).toList());

  void removeFeed(String feedId) {
    final feed = byId(feedId);
    if (feed == null) return;
    final feedBefore = state;
    emit(state.where((f) => f.id != feedId).toList());
    final cascade = _removeClassData(feedId);
    UndoCubit.instance?.record(
      ChangeRecord(
        entries: [
          StateSnapshot(
            cubitId: changeId,
            stateBefore: feedBefore,
            stateAfter: state,
          ),
          ...cascade,
        ],
      ),
    );
  }

  /// Removes the leftover data of a class whose feed entry is already gone.
  ///
  /// Re-adding a class while sync was down (or losing the feeds cubit's
  /// stored copy) can leave imported homework and calendar events whose
  /// classId points at a feed that no longer exists. Those show up under
  /// "Unknown class" in Assignments by class, with no Settings row to remove
  /// them from. This drops the class's imported homework + events as one
  /// undoable step, leaving the feed list untouched.
  void removeOrphanedClass(String classId) {
    if (classId.isEmpty || byId(classId) != null) return;
    final hasEvents = _calendarCubit.state.any((e) => e.feedId == classId);
    final hasNodes = _nodeCubit.state.any(
      (n) => n.classId == classId && n.sourceEventId != null,
    );
    if (!hasEvents && !hasNodes) return;
    final entries = _removeClassData(classId);
    UndoCubit.instance?.record(ChangeRecord(entries: entries));
  }

  /// Cascade shared by [removeFeed] and [removeOrphanedClass]: drop
  /// [classId]'s calendar events and imported homework. Returns the undo
  /// snapshots for the cubits it touched.
  List<StateSnapshot> _removeClassData(String classId) {
    final calendarBefore = _calendarCubit.state;
    _calendarCubit.removeFeedEvents(classId);
    final nodeBefore = _nodeCubit.state;
    _nodeCubit.removeImportedNodesFor(classId);
    final snapshots = [
      StateSnapshot(
        cubitId: _calendarCubit.changeId,
        stateBefore: calendarBefore,
        stateAfter: _calendarCubit.state,
      ),
      StateSnapshot(
        cubitId: _nodeCubit.changeId,
        stateBefore: nodeBefore,
        stateAfter: _nodeCubit.state,
      ),
    ];
    final estimates = estimatesCubit;
    if (estimates != null) {
      final estimatesBefore = estimates.state;
      estimates.forgetFeed(classId);
      if (!identical(estimatesBefore, estimates.state)) {
        snapshots.add(
          StateSnapshot(
            cubitId: estimates.changeId,
            stateBefore: estimatesBefore,
            stateAfter: estimates.state,
          ),
        );
      }
    }
    return snapshots;
  }

  Feed? byId(String feedId) => _byIdMap[feedId];

  List<Feed>? _feedIndexSource;
  Map<String, Feed>? _feedByIdIndex;
  Set<String>? _enabledIdsCache;

  Map<String, Feed> get _byIdMap {
    final s = state;
    if (!identical(s, _feedIndexSource) || _feedByIdIndex == null) {
      _feedByIdIndex = {for (final f in s) f.id: f};
      _enabledIdsCache = {
        for (final f in s)
          if (f.enabled) f.id,
      };
      _feedIndexSource = s;
    }
    return _feedByIdIndex!;
  }

  @override
  void emit(List<Feed> state) {
    _feedIndexSource = null;
    _feedByIdIndex = null;
    _enabledIdsCache = null;
    super.emit(state);
  }

  /// A Google event backed by a writable calendar that can be pushed back
  /// to Google. Recurring instances are included: time-only pushes patch
  /// the instance (affecting just that occurrence), while series pushes
  /// patch the master via [PlannerEvent.seriesId].
  bool isRemoteEditable(PlannerEvent event) {
    if (event.feedId == null || event.sourceUid == null) return false;
    final feed = byId(event.feedId!);
    if (feed == null || feed.kind != FeedKind.google) return false;
    return feed.calendarId != null && feed.calendarId!.isNotEmpty;
  }

  bool isEventEditable(PlannerEvent event) {
    if (!event.isFromFeed) return true;
    return isRemoteEditable(event);
  }

  Feed? _googleFeedFor(PlannerEvent event) {
    final feed = byId(event.feedId ?? '');
    if (feed == null || feed.kind != FeedKind.google) return null;
    if (feed.calendarId == null || feed.calendarId!.isEmpty) return null;
    if (event.sourceUid == null) return null;
    return feed;
  }

  /// Message shown when the Google grant is dead (expired/revoked refresh
  /// token or rejected access token). The server marks these with
  /// `needsReconnect`; surfacing the raw upstream body (e.g. "Token refresh
  /// failed (400): ... Token has been expired or revoked") strands the user
  /// with no action, so substitute directions to the fix.
  static const String googleReconnectMessage =
      'Google account needs reconnect — open Feeds to reconnect.';
  static const String _accountChangedMessage =
      'Account changed. Please try again.';

  /// Runs one remote write and maps its failure to a user-facing message.
  Future<String?> _pushRemote(
    String feedId,
    Future<void> Function() push,
  ) async {
    final generation = accountGeneration;
    if (!isCurrentAccount(generation)) return _accountChangedMessage;
    try {
      await push();
    } on GoogleCalendarException catch (e) {
      if (!isCurrentAccount(generation)) return _accountChangedMessage;
      final message = e.needsReconnect ? googleReconnectMessage : e.message;
      _updateFeedStatus(feedId, error: message);
      return message;
    } catch (e) {
      if (!isCurrentAccount(generation)) return _accountChangedMessage;
      return e.toString();
    }
    if (!isCurrentAccount(generation)) return _accountChangedMessage;
    return null;
  }

  /// Push + full feed refetch. Only used when ONE write can change many
  /// local events (series edits): the write response alone cannot tell us
  /// how Google re-shaped every other occurrence.
  Future<String?> _pushAndResync(
    String feedId,
    Future<void> Function() push,
  ) async {
    final generation = accountGeneration;
    final error = await _pushRemote(feedId, push);
    if (!isCurrentAccount(generation)) return _accountChangedMessage;
    if (error != null) return error;
    await syncFeed(feedId);
    return null;
  }

  /// Applies the canonical event returned by a single-event write. The
  /// response is authoritative for Google-visible fields, so the full feed
  /// refetch that used to hold the editor's save spinner is not needed.
  /// Returns the merged local copy.
  PlannerEvent _applyWriteResult(PlannerEvent saved, PlannerEvent local) {
    final merged = preserveLocalFieldsOnWrite(saved, local);
    _calendarCubit.applySyncedEvent(merged);
    // Defensive: if Google ever answers a write with a different id, keep
    // one copy rather than leaving the old local row behind.
    if (saved.id != local.id) {
      _calendarCubit.removeEventsSilently({local.id});
    }
    return merged;
  }

  /// A sync already in flight fetched the feed BEFORE this write landed;
  /// its snapshot would overwrite the write result a few milliseconds
  /// later. Queue one more pass so the fresh server copy wins. With no
  /// sync running there is no stale snapshot to guard against.
  void _reconcileIfSyncInFlight(String feedId) {
    if (isSyncing.value) _pendingFeedSyncs.add(feedId);
  }

  /// Removes the local copies of a remotely deleted event (the whole
  /// series when Google deleted the master).
  void _removeDeletedLocally(PlannerEvent event, {required bool series}) {
    if (!series) {
      _calendarCubit.removeEventsSilently({event.id});
      return;
    }
    final key = seriesKeyFor(event);
    _calendarCubit.removeEventsSilently({
      event.id,
      // Feed-scoped like the refetch this replaces: another feed mirroring
      // the same master must not lose its rows.
      for (final e in _calendarCubit.state)
        if (e.feedId == event.feedId && key != null && seriesKeyFor(e) == key)
          e.id,
    });
  }

  /// Resolves the remote id for a series-wide write. Real Google masters
  /// carry no `seriesId` (only instances do), so fall back to `sourceUid`.
  static String? seriesRemoteId(PlannerEvent event) {
    final seriesId = event.seriesId;
    if (seriesId != null && seriesId.isNotEmpty) return seriesId;
    final sourceUid = event.sourceUid;
    if (sourceUid != null && sourceUid.isNotEmpty) return sourceUid;
    return null;
  }

  /// Local grouping key for every event in the same repeating series:
  /// the master id for instances, the event's own remote id for masters.
  static String? seriesKeyFor(PlannerEvent event) {
    if (event.seriesId != null && event.seriesId!.isNotEmpty) {
      return event.seriesId;
    }
    if (event.recurrenceRule.isNotEmpty &&
        event.sourceUid != null &&
        event.sourceUid!.isNotEmpty) {
      return event.sourceUid;
    }
    return null;
  }

  /// Pushes a Google event to the server and applies the returned copy
  /// locally, preserving local-only fields. Single-event writes never
  /// refetch the feed; [series] writes do, because one master patch
  /// re-shapes every occurrence. With [series] true the series master is
  /// patched (whole series); otherwise the event's own id is patched (for
  /// a recurring instance that edits just that occurrence).
  /// Returns null on success, else an error message.
  Future<String?> pushEventUpdate(
    PlannerEvent updated, {
    bool series = false,
  }) async {
    final generation = accountGeneration;
    if (!isCurrentAccount(generation)) return _accountChangedMessage;
    if (DemoMode.isActive) {
      final feed = _googleFeedFor(updated);
      if (feed == null) {
        return 'This event can only be edited locally.';
      }
      DemoMocks.googleOverlay.removeWhere((e) => e.id == updated.id);
      DemoMocks.googleOverlay.add(updated);
      DemoMocks.googleTombstones.remove(updated.sourceUid);
      await syncFeed(feed.id);
      return null;
    }
    final feed = _googleFeedFor(updated);
    if (feed == null) {
      return 'This event can only be edited locally.';
    }
    final remoteId = series ? seriesRemoteId(updated) : updated.sourceUid;
    if (remoteId == null || remoteId.isEmpty) {
      return 'This event can only be edited locally.';
    }
    if (series) {
      // A series write re-shapes every other occurrence, which the single
      // write response cannot describe. Keep the full refetch for this
      // path; single-event edits apply the response directly.
      return _pushAndResync(feed.id, () async {
        await _googleService.updateEvent(
          calendarId: feed.calendarId!,
          feedId: feed.id,
          eventId: remoteId,
          event: updated,
          instanceEdit: false,
        );
      });
    }
    var saved = updated;
    final error = await _pushRemote(feed.id, () async {
      saved = await _googleService.updateEvent(
        calendarId: feed.calendarId!,
        feedId: feed.id,
        eventId: remoteId,
        event: updated,
        instanceEdit: updated.isRecurringInstance,
      );
    });
    if (!isCurrentAccount(generation)) return _accountChangedMessage;
    if (error != null) return error;
    _applyWriteResult(saved, updated);
    _reconcileIfSyncInFlight(feed.id);
    return null;
  }

  /// Creates [event] on the Google calendar backing [feed]. The created
  /// event is applied locally from the write response — no refetch, so the
  /// editor closes on one round trip.
  /// Returns a record with an error message (null on success) and the
  /// created event as returned by the server.
  Future<({String? error, PlannerEvent? created})> pushEventCreate({
    required Feed feed,
    required PlannerEvent event,
  }) async {
    final generation = accountGeneration;
    if (!isCurrentAccount(generation)) {
      return (error: _accountChangedMessage, created: null);
    }
    if (DemoMode.isActive) {
      if (feed.kind != FeedKind.google ||
          feed.calendarId == null ||
          feed.calendarId!.isEmpty) {
        return (
          error: 'Choose a Google calendar to save online.',
          created: null,
        );
      }
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final created = PlannerEvent(
        id: 'gcal:${feed.id}:demo-$stamp',
        subject: event.subject,
        notes: event.notes,
        location: event.location,
        start: event.start,
        end: event.end,
        allDay: event.allDay,
        recurrenceRule: event.recurrenceRule,
        feedId: feed.id,
        sourceUid: 'demo-$stamp',
        colorValue: event.colorValue,
        placeId: event.placeId,
        assignees: event.assignees,
        tagIds: event.tagIds,
      );
      DemoMocks.googleOverlay.add(created);
      await syncFeed(feed.id);
      if (!isCurrentAccount(generation)) {
        return (error: _accountChangedMessage, created: null);
      }
      return (error: null, created: created);
    }
    if (feed.kind != FeedKind.google ||
        feed.calendarId == null ||
        feed.calendarId!.isEmpty) {
      return (error: 'Choose a Google calendar to save online.', created: null);
    }
    PlannerEvent? created;
    try {
      created = await _googleService.createEvent(
        calendarId: feed.calendarId!,
        feedId: feed.id,
        event: event,
      );
    } on GoogleCalendarException catch (e) {
      if (!isCurrentAccount(generation)) {
        return (error: _accountChangedMessage, created: null);
      }
      final message = e.needsReconnect ? googleReconnectMessage : e.message;
      _updateFeedStatus(feed.id, error: message);
      return (error: message, created: null);
    } catch (e) {
      if (!isCurrentAccount(generation)) {
        return (error: _accountChangedMessage, created: null);
      }
      return (error: e.toString(), created: null);
    }
    if (!isCurrentAccount(generation)) {
      return (error: _accountChangedMessage, created: null);
    }
    if (event.recurrenceRule.isNotEmpty) {
      // Google expands a recurring create into per-instance rows on the
      // next fetch. Keep that refetch so the local calendar matches the
      // shape every later resync will return.
      await syncFeed(feed.id);
      if (!isCurrentAccount(generation)) {
        return (error: _accountChangedMessage, created: null);
      }
      return (error: null, created: created);
    }
    final merged = _applyWriteResult(created, event);
    _reconcileIfSyncInFlight(feed.id);
    return (error: null, created: merged);
  }

  /// Deletes a Google event on the server and drops the local copy. With
  /// [series] true the whole series is deleted, otherwise just that
  /// occurrence.
  /// Returns null on success, else an error message.
  Future<String?> pushEventDelete(
    PlannerEvent event, {
    bool series = false,
  }) async {
    final generation = accountGeneration;
    if (!isCurrentAccount(generation)) return _accountChangedMessage;
    if (DemoMode.isActive) {
      final feed = _googleFeedFor(event);
      if (feed == null) {
        return 'This event can only be deleted locally.';
      }
      DemoMocks.googleOverlay.removeWhere((e) => e.id == event.id);
      final remoteId = series ? seriesRemoteId(event) : event.sourceUid;
      if (remoteId != null && remoteId.isNotEmpty) {
        DemoMocks.googleTombstones.add(remoteId);
      }
      await syncFeed(feed.id);
      return null;
    }
    final feed = _googleFeedFor(event);
    if (feed == null) {
      return 'This event can only be deleted locally.';
    }
    final remoteId = series ? seriesRemoteId(event) : event.sourceUid;
    if (remoteId == null || remoteId.isEmpty) {
      return 'This event can only be deleted locally.';
    }
    final error = await _pushRemote(feed.id, () async {
      await _googleService.deleteEvent(
        calendarId: feed.calendarId!,
        eventId: remoteId,
      );
    });
    if (!isCurrentAccount(generation)) return _accountChangedMessage;
    if (error != null) return error;
    // The refetch that used to remove the local copy is gone; drop it here.
    _removeDeletedLocally(event, series: series);
    _reconcileIfSyncInFlight(feed.id);
    return null;
  }

  /// Fetches the series master for a recurring instance, or null.
  Future<PlannerEvent?> fetchSeriesMaster(PlannerEvent instance) async {
    final generation = accountGeneration;
    if (!isCurrentAccount(generation)) return null;
    // Demo has no remote masters; edits fall back to local behavior.
    if (DemoMode.isActive) return null;
    final feed = _googleFeedFor(instance);
    final seriesId = instance.seriesId;
    if (feed == null || seriesId == null || seriesId.isEmpty) return null;
    try {
      final master = await _googleService.fetchEvent(
        calendarId: feed.calendarId!,
        feedId: feed.id,
        eventId: seriesId,
      );
      return isCurrentAccount(generation) ? master : null;
    } on GoogleCalendarException catch (e) {
      if (!isCurrentAccount(generation)) return null;
      _updateFeedStatus(
        feed.id,
        error: e.needsReconnect ? googleReconnectMessage : e.message,
      );
      return null;
    } catch (_) {
      return null;
    }
  }

  Set<String> get enabledFeedIds {
    _byIdMap; // refresh cache
    return _enabledIdsCache!;
  }

  bool isFeedVisible(String? feedId) {
    if (feedId == null) return true;
    // Null (unknown feed) stays visible; disabled feeds hide.
    return _byIdMap[feedId]?.enabled ?? true;
  }

  List<PlannerEvent> visibleEvents(List<PlannerEvent> events) {
    final byId = _byIdMap;
    final enabled = _enabledIdsCache!;
    // Fast path: everything enabled — no per-item map lookup.
    if (enabled.length == byId.length) return List.of(events);
    return events.where((e) {
      final id = e.feedId;
      if (id == null) return true;
      // Unknown feeds stay visible (matches isFeedVisible).
      if (!byId.containsKey(id)) return true;
      return enabled.contains(id);
    }).toList();
  }

  /// Homework nodes from disabled feeds are hidden; personal nodes always
  /// show.
  List<Node> visibleNodes(List<Node> nodes) {
    final byId = _byIdMap;
    final enabled = _enabledIdsCache!;
    if (enabled.length == byId.length) return List.of(nodes);
    return nodes.where((n) {
      if (n.sourceEventId == null) return true;
      final id = n.classId;
      if (id == null) return true;
      if (!byId.containsKey(id)) return true;
      return enabled.contains(id);
    }).toList();
  }

  Future<void> syncAll({bool force = false}) {
    if (!force) {
      final last = _lastAutoSync;
      if (last != null &&
          DateTime.now().difference(last) < const Duration(minutes: 15)) {
        return Future.value();
      }
    }
    return _sync(state.where((f) => f.enabled).toList(), force: force);
  }

  Future<void> syncFeed(String feedId) async {
    final feed = byId(feedId);
    if (feed == null || !feed.enabled) return;
    if (isSyncing.value) {
      _pendingFeedSyncs.add(feedId);
      return;
    }
    await _sync([feed], force: true);
  }

  Future<void> syncFeeds(List<String> feedIds) async {
    final feeds = <Feed>[];
    for (final id in feedIds) {
      final feed = byId(id);
      if (feed != null && feed.enabled) feeds.add(feed);
    }
    if (feeds.isEmpty) return;
    await _sync(feeds, force: true);
  }

  /// Canvas assignment id from an iCal UID (`event-assignment-<id>`) or a
  /// homework node/event id (`hw:<feedId>:event-assignment-<id>`).
  static int? _assignmentIdOf(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final tail = raw.split(':').last;
    const prefix = 'event-assignment-';
    if (!tail.startsWith(prefix)) return null;
    return int.tryParse(tail.substring(prefix.length));
  }

  void _updateFeedStatus(
    String feedId, {
    DateTime? lastSyncAt,
    bool clearError = false,
    String? error,
  }) {
    var changed = false;
    final next = state.map((f) {
      if (f.id != feedId) return f;
      final updated = f.copyWith(
        lastSyncAt: lastSyncAt,
        clearLastError: clearError,
        lastError: error,
      );
      if (updated != f) changed = true;
      return updated;
    }).toList();
    if (changed) emit(next);
  }

  /// Records a status change for [feedId] during a batched sync. The last
  /// patch per feed wins; [_flushFeedStatuses] applies them all at once.
  void _queueFeedStatus(
    Map<String, _FeedStatusPatch> patches,
    String feedId, {
    DateTime? lastSyncAt,
    bool clearError = false,
    String? error,
  }) {
    final previous = patches[feedId];
    patches[feedId] = (
      lastSyncAt: lastSyncAt ?? previous?.lastSyncAt,
      clearError: clearError || (previous?.clearError ?? false),
      error: error ?? previous?.error,
    );
  }

  void _flushFeedStatuses(Map<String, _FeedStatusPatch> patches) {
    if (patches.isEmpty) return;
    var changed = false;
    final next = <Feed>[];
    for (final feed in state) {
      final patch = patches[feed.id];
      if (patch == null) {
        next.add(feed);
        continue;
      }
      final updated = feed.copyWith(
        lastSyncAt: patch.lastSyncAt,
        clearLastError: patch.clearError,
        lastError: patch.error,
      );
      if (updated != feed) changed = true;
      next.add(updated);
    }
    if (changed) emit(next);
  }

  @override
  List<Feed>? fromJson(Map<String, dynamic> json) {
    final list = json['feeds'] as List<dynamic>?;
    if (list == null) return null;
    final out = <Feed>[];
    for (final item in list) {
      try {
        out.add(Feed.fromJson(Map<String, dynamic>.from(item as Map)));
      } catch (_) {}
    }
    return out;
  }

  @override
  Map<String, dynamic> toJson(List<Feed> state) => {
    'feeds': state.map((f) => f.toJson()).toList(),
  };
}
