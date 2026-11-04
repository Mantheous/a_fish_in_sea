part of 'feed_cubit.dart';

extension _FeedEventCreation on FeedCubit {
  /// Creates [event] on the Google calendar backing [feed]. The created
  /// event is applied from the write response, or from an expanded
  /// occurrence after a refetch for a recurring event.
  /// Returns a record with an error message (null on success) and the
  /// created event as returned by the server.
  Future<({String? error, PlannerEvent? created})> _pushEventCreate({
    required Feed feed,
    required PlannerEvent event,
  }) async {
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
      final message = e.needsReconnect
          ? FeedCubit.googleReconnectMessage
          : e.message;
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
      if (event.sessions.isNotEmpty ||
          event.actualStart != null ||
          event.actualEnd != null ||
          event.timerStartedAt != null) {
        // Recordings belong to one occurrence, never to every row in the
        // new series. The create response is the master, not that row.
        final occurrences = _calendarCubit.state
            .where(
              (row) =>
                  row.feedId == feed.id &&
                  (row.id == created!.id ||
                      (row.seriesId == created.sourceUid &&
                          row.start.isAtSameMomentAs(created.start))),
            )
            .toList();
        if (byId(feed.id)?.lastError != null || occurrences.length != 1) {
          return (
            error:
                'Couldn’t confirm the recorded time on the new calendar. '
                'The original event has been kept.',
            created: null,
          );
        }
        final merged = _applyWriteResult(occurrences.single, event);
        _reconcileIfSyncInFlight(feed.id);
        return (error: null, created: merged);
      }
      return (error: null, created: created);
    }
    final merged = _applyWriteResult(created, event);
    _reconcileIfSyncInFlight(feed.id);
    return (error: null, created: merged);
  }
}
