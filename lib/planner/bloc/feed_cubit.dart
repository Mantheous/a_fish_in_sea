import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../common/undo/change_record.dart';
import '../../common/undo/revertable_hydrated_cubit.dart';
import '../../common/undo/undo_cubit.dart';
import '../model/feed.dart';
import '../model/planner_event.dart';
import '../model/task.dart';
import '../service/google_calendar_service.dart';
import '../service/ical_service.dart';
import 'calendar_cubit.dart';
import 'task_cubit.dart';

class FeedCubit extends RevertableHydratedCubit<List<Feed>> {
  final CalendarCubit _calendarCubit;
  final TaskCubit _taskCubit;
  final IcalService _icalService;
  final GoogleCalendarService _googleService;
  final String Function() _proxyBase;

  final ValueNotifier<bool> isSyncing = ValueNotifier(false);
  DateTime? _lastAutoSync;
  Timer? _autoResyncTimer;

  /// Exposed so the classes sheet can run the Google connect flow against
  /// the same server/user identity the sync uses.
  GoogleCalendarService get googleService => _googleService;

  FeedCubit({
    required CalendarCubit calendarCubit,
    required TaskCubit taskCubit,
    required IcalService icalService,
    required GoogleCalendarService googleService,
    required String Function() proxyBase,
  })  : _calendarCubit = calendarCubit,
        _taskCubit = taskCubit,
        _icalService = icalService,
        _googleService = googleService,
        _proxyBase = proxyBase,
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
    final feedBefore = toJson(state);
    emit(state.where((f) => f.id != feedId).toList());
    final calendarBefore = _calendarCubit.toJson(_calendarCubit.state);
    _calendarCubit.removeFeedEvents(feedId);
    final taskBefore = _taskCubit.toJson(_taskCubit.state);
    _taskCubit.removeImportedTasksFor(feedId);
    UndoCubit.instance?.record(
      ChangeRecord(entries: [
        StateSnapshot(
          cubitId: changeId,
          before: feedBefore,
          after: toJson(state),
        ),
        StateSnapshot(
          cubitId: _calendarCubit.changeId,
          before: calendarBefore,
          after: _calendarCubit.toJson(_calendarCubit.state),
        ),
        StateSnapshot(
          cubitId: _taskCubit.changeId,
          before: taskBefore,
          after: _taskCubit.toJson(_taskCubit.state),
        ),
      ]),
    );
  }

  Feed? byId(String feedId) {
    for (final feed in state) {
      if (feed.id == feedId) return feed;
    }
    return null;
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

  Future<String?> _pushAndResync(
    String feedId,
    Future<void> Function() push,
  ) async {
    try {
      await push();
    } on GoogleCalendarException catch (e) {
      _updateFeedStatus(feedId, error: e.message);
      return e.message;
    } catch (e) {
      return e.toString();
    }
    await syncFeed(feedId);
    return null;
  }

  /// Pushes a Google event to the server, then re-syncs the feed so local
  /// state matches. With [series] true the series master is patched
  /// (whole series); otherwise the event's own id is patched (for a
  /// recurring instance that edits just that occurrence).
  /// Returns null on success, else an error message.
  Future<String?> pushEventUpdate(
    PlannerEvent updated, {
    bool series = false,
  }) async {
    final feed = _googleFeedFor(updated);
    if (feed == null) {
      return 'This event can only be edited locally.';
    }
    final remoteId = series ? updated.seriesId : updated.sourceUid;
    if (remoteId == null || remoteId.isEmpty) {
      return 'This event can only be edited locally.';
    }
    return _pushAndResync(feed.id, () async {
      await _googleService.updateEvent(
        calendarId: feed.calendarId!,
        feedId: feed.id,
        eventId: remoteId,
        event: updated,
        instanceEdit: !series && updated.isRecurringInstance,
      );
    });
  }

  /// Creates [event] on the Google calendar backing [feed], then re-syncs.
  /// Returns a record with an error message (null on success) and the
  /// created event as returned by the server.
  Future<({String? error, PlannerEvent? created})> pushEventCreate({
    required Feed feed,
    required PlannerEvent event,
  }) async {
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
      _updateFeedStatus(feed.id, error: e.message);
      return (error: e.message, created: null);
    } catch (e) {
      return (error: e.toString(), created: null);
    }
    await syncFeed(feed.id);
    return (error: null, created: created);
  }

  /// Deletes a Google event on the server and re-syncs. With [series] true
  /// the whole series is deleted, otherwise just that occurrence.
  /// Returns null on success, else an error message.
  Future<String?> pushEventDelete(
    PlannerEvent event, {
    bool series = false,
  }) async {
    final feed = _googleFeedFor(event);
    if (feed == null) {
      return 'This event can only be deleted locally.';
    }
    final remoteId = series ? event.seriesId : event.sourceUid;
    if (remoteId == null || remoteId.isEmpty) {
      return 'This event can only be deleted locally.';
    }
    return _pushAndResync(feed.id, () async {
      await _googleService.deleteEvent(
        calendarId: feed.calendarId!,
        eventId: remoteId,
      );
    });
  }

  /// Fetches the series master for a recurring instance, or null.
  Future<PlannerEvent?> fetchSeriesMaster(PlannerEvent instance) async {
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
      _updateFeedStatus(feed.id, error: e.message);
      return null;
    } catch (_) {
      return null;
    }
  }

  Set<String> get enabledFeedIds => {
        for (final feed in state)
          if (feed.enabled) feed.id,
      };

  bool isFeedVisible(String? feedId) {
    if (feedId == null) return true;
    final feed = byId(feedId);
    if (feed == null) return true;
    return feed.enabled;
  }

  List<PlannerEvent> visibleEvents(List<PlannerEvent> events) =>
      events.where((e) => isFeedVisible(e.feedId)).toList();

  List<Task> visibleTasks(List<Task> tasks) => tasks.where((t) {
        if (!t.isImported) return true;
        return isFeedVisible(t.classId);
      }).toList();

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
    if (isSyncing.value) return;
    isSyncing.value = true;
    _lastAutoSync = DateTime.now();
    UndoCubit.instance?.resetHistory();
    try {
      for (final feed in feeds) {
        await _syncOne(feed);
      }
    } finally {
      isSyncing.value = false;
    }
  }

  Future<void> _syncOne(Feed feed) async {
    try {
      final fresh = feed.kind == FeedKind.google
          ? await _syncGoogle(feed)
          : await _syncIcal(feed);
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
              isTaskCandidate(entry.value, feed, now))
            entry.key,
      };
      final events = fresh.map((event) {
        final old = previous[event.id];
        if (old != null) {
          if (old.isTask) {
            return event.copyWith(
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
            );
          }
          // The task flag is local-only (Google never stores it), so a
          // lost calendar flag must not wipe the mark while its shadow
          // task survives (fresh storage, hydrate race). The shadow is
          // the durable record: un-marking deletes it, so a surviving
          // shadow means "still a task" — heal the flag from it.
          final backing = _taskCubit.tasksForEventId(event.id);
          if (backing.isNotEmpty) {
            final shadow = backing.first;
            return event.copyWith(
              isTask: true,
              done: shadow.done,
              completedAt: shadow.completedAt,
              clearCompletedAt: !shadow.done || shadow.completedAt == null,
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
            );
          }
          return event.copyWith(
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
          );
        }
        // Same heal for events the calendar has never seen (or lost):
        // a surviving shadow re-asserts the mark.
        final backing = _taskCubit.tasksForEventId(event.id);
        if (backing.isNotEmpty) {
          final shadow = backing.first;
          return event.copyWith(
            isTask: true,
            done: shadow.done,
            completedAt: shadow.completedAt,
            clearCompletedAt: !shadow.done || shadow.completedAt == null,
            assignees: shadow.assignees,
          );
        }
        // Homework assignments are tasks by default.
        if (feed.createTasks && isTaskCandidate(event, feed, now)) {
          return event.copyWith(isTask: true);
        }
        return event;
      }).toList();
      _calendarCubit.replaceFeedEvents(feed.id, events);
      if (feed.createTasks) {
        _taskCubit.importFromFeed(
          events,
          feed,
          taskOptOutIds: optOuts,
        );
      }
      _updateFeedStatus(
        feed.id,
        lastSyncAt: DateTime.now(),
        clearError: true,
      );
    } catch (e) {
      _updateFeedStatus(feed.id, error: e.toString());
    }
  }

  Future<List<PlannerEvent>> _syncIcal(Feed feed) async {
    final ics = await _icalService.fetchIcs(
      url: feed.url,
      proxyBase: _proxyBase,
    );
    return _icalService.parseIcs(ics, feedId: feed.id, kind: feed.kind);
  }

  Future<List<PlannerEvent>> _syncGoogle(Feed feed) async {
    final calendarId = feed.calendarId;
    if (calendarId == null || calendarId.isEmpty) {
      throw const GoogleCalendarException(
        'Feed has no Google calendar selected',
      );
    }
    return _googleService.fetchEvents(calendarId: calendarId, feedId: feed.id);
  }

  void _updateFeedStatus(
    String feedId, {
    DateTime? lastSyncAt,
    bool clearError = false,
    String? error,
  }) {
    emit(
      state
          .map((f) => f.id == feedId
              ? f.copyWith(
                  lastSyncAt: lastSyncAt,
                  clearLastError: clearError,
                  lastError: error,
                )
              : f)
          .toList(),
    );
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
