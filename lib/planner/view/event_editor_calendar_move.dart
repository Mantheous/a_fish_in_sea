part of 'event_editor.dart';

extension _EventEditorCalendarMove on EventEditorFormState {
  /// Moves an edited event between "This device" (null) and a Google
  /// calendar, or between two Google calendars. Implemented as create in
  /// the destination + delete from the source using the existing push
  /// endpoints, so no server change is needed. Local-only state (task
  /// flag, people, place) is re-asserted on the new copy; backing tasks
  /// for the old id are removed.
  Future<void> _moveEvent(
    BuildContext context, {
    required PlannerEvent base,
    required String? destFeedId,
    required String subject,
    required String? notes,
    required String? location,
    required DateTime start,
    required DateTime end,
    required String rule,
    required bool done,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final feedCubit = context.read<FeedCubit>();
    final calendarCubit = context.read<CalendarCubit>();
    NodeCubit? nodeCubit;
    try {
      nodeCubit = context.read<NodeCubit>();
    } catch (_) {}
    final nodes = nodeCubit;

    final draft = eventDraftForCalendarMove(
      base: base,
      subject: subject,
      notes: notes,
      location: location,
      start: start,
      end: end,
      allDay: _allDay,
      rule: rule,
      taskId: _sourceTaskId,
      isTask: _isTask,
      done: done,
      placeId: _placeId,
      assignees: _people,
      reminderMinutesBefore: _reminderMinutesBefore,
    );

    if (destFeedId == null) {
      // Google → This device: snapshot locally first (never loses data),
      // then delete the remote copy.
      final local = draft;
      _setMoveSaving(true);
      calendarCubit.addEvent(local);
      if (_sourceTaskId != null && nodes != null) {
        try {
          nodes.setCalendarEvent(_sourceTaskId!, local.id);
        } catch (_) {}
      }
      _syncTaskLink(local);
      await EventReminderService.scheduleReminder(local);
      final error = await feedCubit.pushEventDelete(base);
      if (error != null) {
        await _reconcileMoveDelete(feedCubit, calendarCubit, base, local.id);
      }
      if (!mounted) return;
      _setMoveSaving(false);
      if (error != null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Saved to this device, but couldn’t remove the Google copy: $error',
            ),
          ),
        );
        widget.onFinished?.call();
        return;
      }
      if (nodes != null) {
        try {
          nodes.removeNodesForEvent(base.id);
          nodes.clearCalendarEventForEvent(base.id);
        } catch (_) {}
      }
      widget.onFinished?.call();
      return;
    }

    final destFeed = feedCubit.byId(destFeedId);
    if (destFeed == null ||
        destFeed.kind != FeedKind.google ||
        destFeed.calendarId == null ||
        destFeed.calendarId!.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Choose a Google calendar to move to.')),
      );
      return;
    }
    _setMoveSaving(true);
    final result = await feedCubit.pushEventCreate(
      feed: destFeed,
      event: draft,
    );
    if (!mounted) {
      if (result.error == null) {
        _clearMovedRecordings(calendarCubit, result.created?.id ?? draft.id);
      }
      return;
    }
    if (result.error != null) {
      _setMoveSaving(false);
      messenger.showSnackBar(SnackBar(content: Text(result.error!)));
      return;
    }
    final newId = result.created?.id ?? draft.id;
    if (_sourceTaskId != null && nodes != null) {
      try {
        nodes.setCalendarEvent(_sourceTaskId!, newId);
      } catch (_) {}
    }
    _applyLocalAssignees(newId);
    _restorePlaceId(newId);
    _restoreReminder(newId);
    _mirrorAssigneesToSourceTask();
    _applyTaskLinkPostSync(newId);
    await EventReminderService.scheduleReminder(
      calendarCubit.byId(newId) ?? draft,
    );
    if (base.isFromFeed) {
      final deleteError = await feedCubit.pushEventDelete(base);
      if (deleteError != null) {
        await _reconcileMoveDelete(feedCubit, calendarCubit, base, newId);
      }
      if (!mounted) return;
      _setMoveSaving(false);
      if (deleteError != null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Saved to ${destFeed.name}, but couldn’t remove the original: $deleteError',
            ),
          ),
        );
        widget.onFinished?.call();
        return;
      }
      if (nodes != null) {
        try {
          nodes.removeNodesForEvent(base.id);
          nodes.clearCalendarEventForEvent(base.id);
        } catch (_) {}
      }
    } else {
      calendarCubit.deleteEvent(base.id);
      if (nodes != null) {
        try {
          nodes.removeNodesForEvent(base.id);
          nodes.clearCalendarEventForEvent(base.id);
        } catch (_) {}
      }
      if (!mounted) return;
      _setMoveSaving(false);
    }
    widget.onFinished?.call();
  }

  /// A failed response does not prove Google rejected the deletion. Keep
  /// the durable destination recordings throughout the confirmation fetch.
  Future<void> _reconcileMoveDelete(
    FeedCubit feeds,
    CalendarCubit calendar,
    PlannerEvent source,
    String destinationId,
  ) async {
    final feedId = source.feedId!;
    // syncFeed queues rather than awaits a fetch if another sync is active.
    final canConfirm =
        feeds.byId(feedId)?.enabled == true && !feeds.isSyncing.value;
    await feeds.syncFeed(feedId);
    if (calendar.byId(destinationId) == null) return;
    if (canConfirm &&
        feeds.byId(feedId)?.lastError == null &&
        calendar.byId(source.id) != null) {
      _clearMovedRecordings(calendar, destinationId);
    } else {
      // Deleted or still uncertain: the destination owns the recordings.
      // Clear a stale source locally so later syncs preserve just one owner,
      // even when this fetch failed or the editor has already closed.
      _clearMovedRecordings(calendar, source.id);
    }
  }

  /// Clear only the duplicate after retaining the recording on its owner.
  void _clearMovedRecordings(CalendarCubit calendar, String eventId) {
    final copy = calendar.byId(eventId);
    if (copy == null) return;
    calendar.updateEvent(
      copy.copyWith(
        sessions: const [],
        clearActualStart: true,
        clearActualEnd: true,
        clearTimerStartedAt: true,
      ),
    );
  }
}
