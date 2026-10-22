import 'dart:async';

import 'package:flutter/foundation.dart';

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
  })  : _calendarCubit = calendarCubit,
        _nodeCubit = nodeCubit,
        _icalService = icalService,
        _googleService = googleService,
        _proxyBase = proxyBase,
        _canvasService = canvasService,
        super(const []);

  @override
  Future<void> close() {
    _autoResyncTimer?.cancel();
    isSyncing.dispose();
    return super.close();
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
      ChangeRecord(entries: [
        StateSnapshot(
          cubitId: changeId,
          stateBefore: feedBefore,
          stateAfter: state,
        ),
        ...cascade,
      ]),
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
    final hasNodes = _nodeCubit.state
        .any((n) => n.classId == classId && n.sourceEventId != null);
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
        snapshots.add(StateSnapshot(
          cubitId: estimates.changeId,
          stateBefore: estimatesBefore,
          stateAfter: estimates.state,
        ));
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

  /// Runs one remote write and maps its failure to a user-facing message.
  Future<String?> _pushRemote(
    String feedId,
    Future<void> Function() push,
  ) async {
    try {
      await push();
    } on GoogleCalendarException catch (e) {
      final message = e.needsReconnect ? googleReconnectMessage : e.message;
      _updateFeedStatus(feedId, error: message);
      return message;
    } catch (e) {
      return e.toString();
    }
    return null;
  }

  /// Push + full feed refetch. Only used when ONE write can change many
  /// local events (series edits): the write response alone cannot tell us
  /// how Google re-shaped every other occurrence.
  Future<String?> _pushAndResync(
    String feedId,
    Future<void> Function() push,
  ) async {
    final error = await _pushRemote(feedId, push);
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
        if (e.feedId == event.feedId &&
            key != null &&
            seriesKeyFor(e) == key)
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
    final remoteId =
        series ? seriesRemoteId(updated) : updated.sourceUid;
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
    if (DemoMode.isActive) {
      if (feed.kind != FeedKind.google ||
          feed.calendarId == null ||
          feed.calendarId!.isEmpty) {
        return (
          error: 'Choose a Google calendar to save online.',
          created: null
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
      final message = e.needsReconnect ? googleReconnectMessage : e.message;
      _updateFeedStatus(feed.id, error: message);
      return (error: message, created: null);
    } catch (e) {
      return (error: e.toString(), created: null);
    }
    if (event.recurrenceRule.isNotEmpty) {
      // Google expands a recurring create into per-instance rows on the
      // next fetch. Keep that refetch so the local calendar matches the
      // shape every later resync will return.
      await syncFeed(feed.id);
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
    if (error != null) return error;
    // The refetch that used to remove the local copy is gone; drop it here.
    _removeDeletedLocally(event, series: series);
    _reconcileIfSyncInFlight(feed.id);
    return null;
  }

  /// Fetches the series master for a recurring instance, or null.
  Future<PlannerEvent?> fetchSeriesMaster(PlannerEvent instance) async {
    // Demo has no remote masters; edits fall back to local behavior.
    if (DemoMode.isActive) return null;
    final feed = _googleFeedFor(instance);
    final seriesId = instance.seriesId;
    if (feed == null || seriesId == null || seriesId.isEmpty) return null;
    try {
      return await _googleService.fetchEvent(
        calendarId: feed.calendarId!,
        feedId: feed.id,
        eventId: seriesId,
      );
    } on GoogleCalendarException catch (e) {
      _updateFeedStatus(
          feed.id, error: e.needsReconnect ? googleReconnectMessage : e.message);
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

  Future<void> _sync(List<Feed> feeds, {required bool force}) async {
    if (isSyncing.value) {
      _pendingFeedSyncs.addAll(feeds.map((f) => f.id));
      return;
    }
    isSyncing.value = true;
    _lastAutoSync = DateTime.now();
    // Demo entry/exit swaps the whole feed list mid-sync: a sync that
    // started in demo must not write into real storage after a quick exit
    // (and vice versa). [_syncOne] bails per feed; the Canvas heal below
    // is the only other writer, so skip it on a flip too.
    final startedInDemo = DemoMode.isActive;
    // Status rows (lastSyncAt / lastError) change on every resync. Patch
    // them in ONE emit at the end: a multi-feed sync must rebuild feed
    // watchers once, not once per feed.
    final statusPatches = <String, _FeedStatusPatch>{};
    try {
      for (final feed in feeds) {
        await _syncOne(feed, statusPatches);
      }
      // Submitted-in-Canvas homework completes itself. Runs after the
      // iCal import so fresh nodes are covered too; failures never fail
      // the feed sync (reconnect is handled in the classes sheet).
      if (DemoMode.isActive == startedInDemo) {
        await _applyCanvasCompletions(feeds);
      }
    } finally {
      _flushFeedStatuses(statusPatches);
      isSyncing.value = false;
      if (_pendingFeedSyncs.isNotEmpty) {
        final pending = _pendingFeedSyncs.toList();
        _pendingFeedSyncs.clear();
        unawaited(syncFeeds(pending));
      }
    }
  }

  Future<void> _syncOne(
    Feed feed,
    Map<String, _FeedStatusPatch> statusPatches,
  ) async {
    try {
      final startedInDemo = DemoMode.isActive;
      final fresh = feed.kind == FeedKind.google
          ? await _syncGoogle(feed)
          : await _syncIcal(feed);
      if (DemoMode.isActive != startedInDemo) return;
      final now = DateTime.now();
      final previous = <String, PlannerEvent>{
        for (final e in _calendarCubit.state)
          if (e.feedId == feed.id) e.id: e,
      };
      // Events the user explicitly un-marked as tasks: they qualify by
      // heuristic but carry isTask=false from a previous sync. Skipping
      // them keeps the un-check sticky across re-syncs.
      final optOuts = <String>{
        for (final entry in previous.entries)
          if (!entry.value.isTask &&
              isNodeCandidate(entry.value, feed, now))
            entry.key,
      };
      final events = fresh.map((event) {
        final old = previous[event.id];
        if (old != null) {
          if (old.isTask) {
            return preserveLocalFeedMetadata(event.copyWith(
              isTask: old.isTask,
              done: old.done,
              completedAt: old.completedAt,
              clearCompletedAt: !old.done || old.completedAt == null,
              taskId: old.taskId,
              clearTaskId: old.taskId == null,
              placeId: old.placeId,
              clearPlaceId: old.placeId == null,
              assignees: old.assignees,
              actualStart: old.actualStart,
              clearActualStart: old.actualStart == null,
              actualEnd: old.actualEnd,
              clearActualEnd: old.actualEnd == null,
              timerStartedAt: old.timerStartedAt,
              clearTimerStartedAt: old.timerStartedAt == null,
              failed: old.failed,
            ), old);
          }
          // The task flag is local-only (Google never stores it), so a
          // lost calendar flag must not wipe the mark while its backing
          // node survives (fresh storage, hydrate race). The node is
          // the durable record: un-marking deletes it, so a surviving
          // node means "still actionable" — heal the flag from it.
          final backing = _nodeCubit.nodesForEventId(event.id);
          if (backing.isNotEmpty) {
            final shadow = backing.first;
            return preserveLocalFeedMetadata(event.copyWith(
              isTask: true,
              done: shadow.isDone,
              completedAt: shadow.completedAt,
              clearCompletedAt:
                  !shadow.isDone || shadow.completedAt == null,
              taskId: old.taskId,
              clearTaskId: old.taskId == null,
              placeId: old.placeId,
              clearPlaceId: old.placeId == null,
              assignees: shadow.assignees,
              actualStart: old.actualStart,
              clearActualStart: old.actualStart == null,
              actualEnd: old.actualEnd,
              clearActualEnd: old.actualEnd == null,
              timerStartedAt: old.timerStartedAt,
              clearTimerStartedAt: old.timerStartedAt == null,
              failed: old.failed,
            ), old);
          }
          return preserveLocalFeedMetadata(event.copyWith(
            isTask: old.isTask,
            done: old.done,
            completedAt: old.completedAt,
            clearCompletedAt: !old.done || old.completedAt == null,
            taskId: old.taskId,
            clearTaskId: old.taskId == null,
            placeId: old.placeId,
            clearPlaceId: old.placeId == null,
            assignees: old.assignees,
            actualStart: old.actualStart,
            clearActualStart: old.actualStart == null,
            actualEnd: old.actualEnd,
            clearActualEnd: old.actualEnd == null,
            timerStartedAt: old.timerStartedAt,
            clearTimerStartedAt: old.timerStartedAt == null,
            failed: old.failed,
          ), old);
        }
        // Same heal for events the calendar has never seen (or lost):
        // a surviving node re-asserts the mark.
        final backing = _nodeCubit.nodesForEventId(event.id);
        if (backing.isNotEmpty) {
          final shadow = backing.first;
          return event.copyWith(
            isTask: true,
            done: shadow.isDone,
            completedAt: shadow.completedAt,
            clearCompletedAt: !shadow.isDone || shadow.completedAt == null,
            assignees: shadow.assignees,
          );
        }
        // Homework assignments are actionable by default.
        if (feed.createTasks && isNodeCandidate(event, feed, now)) {
          return event.copyWith(isTask: true);
        }
        return event;
      }).toList();
      _calendarCubit.replaceFeedEvents(feed.id, events);
      if (feed.createTasks) {
        _nodeCubit.importFromFeed(
          events,
          feed,
          taskOptOutIds: optOuts,
          assignmentRules: assignmentRulesProvider?.call() ?? const [],
        );
      }
      _queueFeedStatus(
        statusPatches,
        feed.id,
        lastSyncAt: DateTime.now(),
        clearError: true,
      );
    } catch (e) {
      final message = e is GoogleCalendarException && e.needsReconnect
          ? googleReconnectMessage
          : e.toString();
      _queueFeedStatus(statusPatches, feed.id, error: message);
    }
  }

  Future<List<PlannerEvent>> _syncIcal(Feed feed) async {
    if (DemoMode.isActive) {
      // Mock fetch: same shape as a parsed feed, generated fresh so the
      // refresh buttons visibly do something. Local done/task flags are
      // preserved by [_syncOne], exactly like a real re-sync.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final now = DateTime.now();
      return DemoData.feedEvents(now)
          .where((e) => e.feedId == feed.id)
          .toList();
    }
    // Server-side fetching when signed in: the server fetches the URL and
    // caches the ICS, so every device parses identical bytes (and web
    // avoids CORS). Any failure falls back to the direct/proxy fetch.
    final sc = syncClient;
    if (sc != null) {
      try {
        await sc.refreshFeedSnapshot(feedId: feed.id, url: feed.url);
        final snap = await sc.fetchFeedSnapshot(feed.id);
        final ics = snap?['ics'] as String?;
        if (ics != null && ics.isNotEmpty) {
          return _icalService.parseIcs(ics, feedId: feed.id, kind: feed.kind);
        }
      } catch (_) {}
    }
    final ics = await _icalService.fetchIcs(
      url: feed.url,
      proxyBase: _proxyBase,
    );
    return _icalService.parseIcs(ics, feedId: feed.id, kind: feed.kind);
  }

  Future<List<PlannerEvent>> _syncGoogle(Feed feed) async {
    if (DemoMode.isActive) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!DemoMocks.googleConnected) {
        throw const GoogleCalendarException(
          'Demo Google is disconnected — reconnect from Classes & calendars.',
          needsReconnect: true,
        );
      }
      final now = DateTime.now();
      final tombstoned = DemoMocks.googleTombstones;
      if (feed.id == DemoData.googleFeedId) {
        final byId = <String, PlannerEvent>{
          for (final e in DemoData.feedEvents(now))
            if (e.feedId == feed.id) e.id: e,
        };
        for (final extra in DemoMocks.googleOverlay) {
          if (extra.feedId == feed.id) byId[extra.id] = extra;
        }
        return byId.values
            .where((e) => !tombstoned.contains(e.sourceUid))
            .toList();
      }
      // A calendar the user added mid-demo: generic mock events plus any
      // overlay edits made to this feed.
      final today = DateTime(now.year, now.month, now.day);
      return [
        PlannerEvent(
          id: '${feed.id}:demo-kickoff',
          subject: 'Mock sync for ${feed.name}',
          notes: 'This calendar was added during the demo — real '
              'calendars list here after a Google connect.',
          start: DateTime(today.year, today.month, today.day + 1, 18),
          end: DateTime(today.year, today.month, today.day + 1, 20),
          feedId: feed.id,
          sourceUid: 'demo-kickoff',
        ),
        for (final extra in DemoMocks.googleOverlay)
          if (extra.feedId == feed.id) extra,
      ];
    }
    final calendarId = feed.calendarId;
    if (calendarId == null || calendarId.isEmpty) {
      throw const GoogleCalendarException(
        'Feed has no Google calendar selected',
      );
    }
    return _googleService.fetchEvents(calendarId: calendarId, feedId: feed.id);
  }

  /// Marks homework done when Canvas reports it submitted or excused.
  ///
  /// The iCal feed carries no completion state, so submitted work piles
  /// up as overdue forever. This heals that: one planner-API read per
  /// sync, then silent batched emits (syncs stay non-undoable, like the
  /// iCal import itself). Local state always wins — only open nodes and
  /// open task-events are touched, never done/failed/skipped, and
  /// anything Canvas doesn't report stays exactly as it was.
  Future<void> _applyCanvasCompletions(List<Feed> syncedFeeds) async {
    final canvas = _canvasService;
    if (canvas == null) return;
    final canvasFeedIds = <String>{
      for (final feed in syncedFeeds)
        if (feed.kind == FeedKind.canvas && feed.createTasks) feed.id,
    };
    if (canvasFeedIds.isEmpty) return;
    late final List<CanvasSubmission> submissions;
    if (DemoMode.isActive) {
      // Mock planner API: one submitted + one excused heal on sync, while
      // the bare-graded item must stay open (conservative rule demo).
      if (!DemoMocks.canvasConnected) return;
      submissions = DemoData.canvasSubmissions();
    } else {
      try {
        submissions = await canvas.fetchSubmissions();
      } catch (_) {
        return;
      }
    }
    final doneIds = <int>{
      for (final s in submissions)
        if (s.countsAsDone) s.assignmentId,
    };
    if (doneIds.isEmpty) return;
    final now = DateTime.now();

    // Calendar task-events first: only open ones whose backing nodes
    // carry no explicit failed/skipped decision.
    final events = _calendarCubit.state;
    final markedByFeed = <String, List<PlannerEvent>>{};
    var eventsChanged = false;
    for (final event in events) {
      final feedId = event.feedId;
      if (feedId == null || !canvasFeedIds.contains(feedId)) continue;
      if (!event.isTask || event.done) continue;
      final aid = _assignmentIdOf(event.sourceUid);
      if (aid == null || !doneIds.contains(aid)) continue;
      var keepOpen = false;
      for (final node in _nodeCubit.nodesForEventId(event.id)) {
        if (node.status == NodeStatus.failed ||
            node.status == NodeStatus.skipped) {
          // An explicit local decision — leave the event alone.
          keepOpen = true;
          break;
        }
      }
      if (keepOpen) continue;
      markedByFeed
          .putIfAbsent(feedId, () => [])
          .add(event.copyWith(done: true, completedAt: now));
      eventsChanged = true;
    }
    if (eventsChanged) {
      final byId = <String, PlannerEvent>{
        for (final e in markedByFeed.values.expand((l) => l)) e.id: e,
      };
      final perFeed = <String, List<PlannerEvent>>{};
      for (final event in events) {
        final feedId = event.feedId;
        if (feedId == null || !markedByFeed.containsKey(feedId)) continue;
        perFeed
            .putIfAbsent(feedId, () => [])
            .add(byId[event.id] ?? event);
      }
      for (final entry in perFeed.entries) {
        _calendarCubit.replaceFeedEvents(entry.key, entry.value);
      }
    }

    // Homework nodes, including stale ones whose events aged out of the
    // feed window: node ids look like `hw:<feedId>:event-assignment-<aid>`.
    final nodes = _nodeCubit.state;
    var nodesChanged = false;
    final next = <Node>[
      for (final node in nodes)
        if (node.isOpen &&
            node.sourceEventId != null &&
            node.classId != null &&
            canvasFeedIds.contains(node.classId) &&
            doneIds.contains(_assignmentIdOf(node.sourceEventId) ?? -1))
          () {
            nodesChanged = true;
            return node.copyWith(
              status: NodeStatus.done,
              completedAt: now,
            );
          }()
        else
          node,
    ];
    if (nodesChanged) _nodeCubit.emitSilent(next);
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
  Map<String, dynamic> toJson(List<Feed> state) =>
      {'feeds': state.map((f) => f.toJson()).toList()};
}
