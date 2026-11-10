part of 'feed_cubit.dart';

extension _FeedSync on FeedCubit {
  Future<void> _sync(List<Feed> feeds, {required bool force}) async {
    final generation = accountGeneration;
    if (!isCurrentAccount(generation)) return;
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
        if (!isCurrentAccount(generation)) return;
        await _syncOne(feed, statusPatches, generation);
      }
      // Submitted-in-Canvas homework completes itself. Runs after the
      // iCal import so fresh nodes are covered too; failures never fail
      // the feed sync (reconnect is handled in the classes sheet).
      if (isCurrentAccount(generation) && DemoMode.isActive == startedInDemo) {
        await _applyCanvasCompletions(feeds);
      }
    } finally {
      if (isCurrentAccount(generation)) {
        _flushFeedStatuses(statusPatches);
        isSyncing.value = false;
        if (_pendingFeedSyncs.isNotEmpty) {
          final pending = _pendingFeedSyncs.toList();
          _pendingFeedSyncs.clear();
          unawaited(syncFeeds(pending));
        }
      }
    }
  }

  Future<void> _syncOne(
    Feed feed,
    Map<String, _FeedStatusPatch> statusPatches,
    int generation,
  ) async {
    try {
      final startedInDemo = DemoMode.isActive;
      final fresh = feed.kind == FeedKind.google
          ? await _syncGoogle(feed)
          : await _syncIcal(feed);
      if (!isCurrentAccount(generation) || DemoMode.isActive != startedInDemo) {
        return;
      }
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
          if (!entry.value.isTask && isNodeCandidate(entry.value, feed, now))
            entry.key,
      };
      final events = fresh.map((event) {
        final old = previous[event.id];
        if (old != null) {
          if (old.isTask) {
            return preserveLocalFeedMetadata(
              event.copyWith(
                isTask: old.isTask,
                done: old.done,
                completedAt: old.completedAt,
                clearCompletedAt: !old.done || old.completedAt == null,
                taskId: old.taskId,
                clearTaskId: old.taskId == null,
                placeId: old.placeId,
                clearPlaceId: old.placeId == null,
                assignees: old.assignees,
                sessions: old.sessions,
                actualStart: old.actualStart,
                clearActualStart: old.actualStart == null,
                actualEnd: old.actualEnd,
                clearActualEnd: old.actualEnd == null,
                timerStartedAt: old.timerStartedAt,
                clearTimerStartedAt: old.timerStartedAt == null,
                failed: old.failed,
              ),
              old,
            );
          }
          // The task flag is local-only (Google never stores it), so a
          // lost calendar flag must not wipe the mark while its backing
          // node survives (fresh storage, hydrate race). The node is
          // the durable record: un-marking deletes it, so a surviving
          // node means "still actionable" — heal the flag from it.
          final backing = _nodeCubit.nodesForEventId(event.id);
          if (backing.isNotEmpty) {
            final shadow = backing.first;
            return preserveLocalFeedMetadata(
              event.copyWith(
                isTask: true,
                done: shadow.isDone,
                completedAt: shadow.completedAt,
                clearCompletedAt: !shadow.isDone || shadow.completedAt == null,
                taskId: old.taskId,
                clearTaskId: old.taskId == null,
                placeId: old.placeId,
                clearPlaceId: old.placeId == null,
                assignees: shadow.assignees,
                sessions: old.sessions,
                actualStart: old.actualStart,
                clearActualStart: old.actualStart == null,
                actualEnd: old.actualEnd,
                clearActualEnd: old.actualEnd == null,
                timerStartedAt: old.timerStartedAt,
                clearTimerStartedAt: old.timerStartedAt == null,
                failed: old.failed,
              ),
              old,
            );
          }
          return preserveLocalFeedMetadata(
            event.copyWith(
              isTask: old.isTask,
              done: old.done,
              completedAt: old.completedAt,
              clearCompletedAt: !old.done || old.completedAt == null,
              taskId: old.taskId,
              clearTaskId: old.taskId == null,
              placeId: old.placeId,
              clearPlaceId: old.placeId == null,
              assignees: old.assignees,
              sessions: old.sessions,
              actualStart: old.actualStart,
              clearActualStart: old.actualStart == null,
              actualEnd: old.actualEnd,
              clearActualEnd: old.actualEnd == null,
              timerStartedAt: old.timerStartedAt,
              clearTimerStartedAt: old.timerStartedAt == null,
              failed: old.failed,
            ),
            old,
          );
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
      if (!isCurrentAccount(generation)) return;
      final message = e is GoogleCalendarException && e.needsReconnect
          ? FeedCubit.googleReconnectMessage
          : e.toString();
      _queueFeedStatus(statusPatches, feed.id, error: message);
    }
  }

  Future<List<PlannerEvent>> _syncIcal(Feed feed) async {
    final generation = accountGeneration;
    if (DemoMode.isActive) {
      // Mock fetch: same shape as a parsed feed, generated fresh so the
      // refresh buttons visibly do something. Local done/task flags are
      // preserved by [_syncOne], exactly like a real re-sync.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final now = DateTime.now();
      return DemoData.feedEvents(
        now,
      ).where((e) => e.feedId == feed.id).toList();
    }
    // Server-side fetching when signed in: the server fetches the URL and
    // caches the ICS, so every device parses identical bytes (and web
    // avoids CORS). Any failure falls back to the direct/proxy fetch.
    final sc = syncClient;
    if (sc != null) {
      try {
        await sc.refreshFeedSnapshot(feedId: feed.id, url: feed.url);
        if (!isCurrentAccount(generation)) return [];
        final snap = await sc.fetchFeedSnapshot(feed.id);
        if (!isCurrentAccount(generation)) return [];
        final ics = snap?['ics'] as String?;
        if (ics != null && ics.isNotEmpty) {
          return _icalService.parseIcs(ics, feedId: feed.id, kind: feed.kind);
        }
      } catch (_) {}
    }
    if (!isCurrentAccount(generation)) return [];
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
          notes:
              'This calendar was added during the demo — real '
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
    final generation = accountGeneration;
    final startedInDemo = DemoMode.isActive;
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
    if (!isCurrentAccount(generation) || DemoMode.isActive != startedInDemo) {
      return;
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
      final aid = FeedCubit._assignmentIdOf(event.sourceUid);
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
        perFeed.putIfAbsent(feedId, () => []).add(byId[event.id] ?? event);
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
            doneIds.contains(
              FeedCubit._assignmentIdOf(node.sourceEventId) ?? -1,
            ))
          () {
            nodesChanged = true;
            return node.copyWith(status: NodeStatus.done, completedAt: now);
          }()
        else
          node,
    ];
    if (nodesChanged) _nodeCubit.emitSilent(next);
  }
}
