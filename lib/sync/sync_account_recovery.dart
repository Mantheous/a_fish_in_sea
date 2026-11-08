part of 'sync_engine.dart';

/// Account ownership, snapshots and recovery are separate from the sync
/// protocol. Domain stores and metadata persist independently, so removal
/// uses a durable intent followed by acknowledged writes before ownership
/// can be released.
extension AccountRecovery on SyncEngine {
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
    settings.resetSynced();
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
        collections: {for (final c in SyncEngine.collections) c: _extract(c)},
      );
    }
    return next;
  }

  void _applySnapshot(AccountSnapshot snap) {
    _applyingRemote = true;
    try {
      for (final entry in snap.collections.entries) {
        if (entry.value.isNotEmpty) _apply(entry.key, entry.value);
      }
    } finally {
      _applyingRemote = false;
    }
  }

  /// A Keep sign-out leaves live edits authoritative. If a whole collection
  /// has since disappeared, its saved metadata cannot be used as evidence
  /// of deletions, even for collections below the mass-deletion threshold.
  ({String? cursor, Map<String, ItemMeta> items}) _restoredBookkeeping(
    AccountSnapshot snap,
  ) {
    final items = <String, ItemMeta>{};
    final hasContent = <String, bool>{};
    for (final entry in snap.items.entries) {
      final slash = entry.key.indexOf('/');
      if (slash > 0 &&
          !hasContent.putIfAbsent(
            entry.key.substring(0, slash),
            () => _extract(entry.key.substring(0, slash)).isNotEmpty,
          )) {
        continue;
      }
      items[entry.key] = entry.value;
    }
    return (
      cursor: items.length == snap.items.length ? snap.cursor : null,
      items: items,
    );
  }

  Future<void> _persistMeta() =>
      HydratedBloc.storage.write(meta.storageToken, meta.toJson(meta.state));

  /// HydratedBloc does not await onChange writes. Explicitly await the
  /// cleared states (including stores that were already empty) before
  /// marking removal complete. Failed writes leave the durable intent set.
  Future<void> _persistCollections() => Future.wait([
    HydratedBloc.storage.write(nodes.storageToken, nodes.toJson(nodes.state)),
    HydratedBloc.storage.write(
      events.storageToken,
      events.toJson(events.state),
    ),
    HydratedBloc.storage.write(feeds.storageToken, feeds.toJson(feeds.state)),
    HydratedBloc.storage.write(
      transactions.storageToken,
      transactions.toJson(transactions.state),
    ),
    HydratedBloc.storage.write(
      places.storageToken,
      places.toJson(places.state),
    ),
    HydratedBloc.storage.write(
      reporting.storageToken,
      reporting.toJson(reporting.state),
    ),
    HydratedBloc.storage.write(
      tracking.storageToken,
      tracking.toJson(tracking.state),
    ),
    HydratedBloc.storage.write(
      settings.storageToken,
      settings.toJson(settings.state),
    ),
    HydratedBloc.storage.write(
      waterfall.storageToken,
      waterfall.toJson(waterfall.state),
    ),
    HydratedBloc.storage.write(plaid.storageToken, plaid.toJson(plaid.state)),
  ]);

  Future<void> _finishPendingRemoval() async {
    if (!meta.state.pendingRemoval) return;
    // Also cover retries after a failed metadata write in this process.
    await _persistMeta();
    clearLocalAccountData();
    await _persistCollections();
    meta.reset(
      clearLastEmail: true,
      pendingRemoval: false,
      accountSnapshots: meta.state.accountSnapshots,
    );
    await _persistMeta();
  }

  /// Preserve unsynced work before clearing any domain store. Keep the
  /// outgoing owner until all clearing has completed, including on restart.
  Future<void> signOut({bool clearLocalData = false}) async {
    if (_accountTransition != null) return _accountTransition;
    _epoch++;
    _running = false;
    status.value = EngineStatus.idle;
    lastError = null;
    final transition = _signOut(clearLocalData);
    _accountTransition = transition;
    try {
      await transition;
    } finally {
      _accountTransition = null;
    }
  }

  Future<void> _signOut(bool clearLocalData) async {
    if (meta.state.pendingRemoval) {
      // Never replace the original snapshot with partially cleared data.
      await _finishPendingRemoval();
    } else {
      final email = auth.state.email.trim().toLowerCase();
      meta.reset(
        lastEmail: email.isEmpty ? meta.state.lastEmail : email,
        pendingRemoval: clearLocalData,
        accountSnapshots: email.isEmpty
            ? meta.state.accountSnapshots
            : _withSnapshotFor(email),
      );
      await _persistMeta();
      if (clearLocalData) await _finishPendingRemoval();
    }
    // The sign-in screen cannot expose another account during the writes.
    plaid.clearLocalSession();
    auth.logout();
  }

  Future<void> _prepareAccount(String email) async {
    await _finishPendingRemoval();
    final previous = meta.state.lastEmail?.trim().toLowerCase();
    if (previous != null &&
        previous.isNotEmpty &&
        email.isNotEmpty &&
        previous != email) {
      meta.reset(
        lastEmail: previous,
        pendingRemoval: true,
        accountSnapshots: _withSnapshotFor(previous),
      );
      // Authentication waits here before emitting the signed-in state.
      // Persist the outgoing snapshot before any domain writes.
      await _persistMeta();
      await _finishPendingRemoval();
    }
    if (email.isEmpty) return;
    final restored = meta.state.accountSnapshots[email];
    final wiped = (meta.state.lastEmail ?? '').trim().toLowerCase() != email;
    final hasBaseline =
        restored != null &&
        (restored.cursor != null || restored.items.isNotEmpty);
    if (meta.state.cursor == null &&
        meta.state.items.isEmpty &&
        (hasBaseline || (wiped && restored != null))) {
      // Claim the incoming ownership before any restored collection writes.
      // A subsequent switch will then clear even a partial restoration.
      meta.save(lastEmail: email);
      await _persistMeta();
      if (wiped) _applySnapshot(restored);
      final bookkeeping = _restoredBookkeeping(restored);
      meta.reset(
        lastEmail: email,
        cursor: bookkeeping.cursor,
        items: bookkeeping.items,
        accountSnapshots: meta.state.accountSnapshots,
      );
    } else if (previous != email) {
      meta.save(lastEmail: email);
      await _persistMeta();
    }
  }

  /// Discard the saved baseline too: an existing snapshot must never reseed
  /// an incremental cursor after the user explicitly requests a full pull.
  Future<void> restoreMissingItemsFromCloud() async {
    final email = auth.state.email.trim().toLowerCase();
    final snapshots = Map<String, AccountSnapshot>.of(
      meta.state.accountSnapshots,
    );
    final snapshot = snapshots[email];
    if (snapshot != null) {
      snapshots[email] = snapshot.copyWith(clearCursor: true, items: const {});
    }
    meta.reset(accountSnapshots: snapshots);
    await _persistMeta();
    await syncNow();
  }
}
