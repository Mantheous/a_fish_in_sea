part of 'sync_engine.dart';

/// Account ownership, snapshots and recovery are separate from the sync
/// protocol. Domain stores and metadata persist independently, so removal
/// uses a durable intent followed by acknowledged writes before ownership
/// can be released.
extension AccountRecovery on SyncEngine {
  List<AccountMutationFence<dynamic>> get _accountStores => [
    nodes,
    events,
    feeds,
    transactions,
    places,
    reporting,
    tracking,
    settings,
    waterfall,
    plaid,
  ];

  void _blockAccountMutations() {
    LocationService.stopForegroundSampling();
    for (final store in _accountStores) {
      store.accountMutationsBlocked = true;
      store.invalidateAccountOperations();
    }
    AccountMutationFence.write(_accountStores, tracking.stopRecording);
    UndoCubit.instance?.resetHistory();
  }

  void _unblockAccountMutations() {
    for (final store in _accountStores) {
      store.accountMutationsBlocked = false;
    }
  }

  /// Clears all local domain cubits and bank session state. Used on sign-out
  /// and when switching to a different account so one user's local data can
  /// never be merged/pushed into another user's cloud account.
  void clearLocalAccountData() {
    AccountMutationFence.write(_accountStores, () {
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
    });
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
      AccountMutationFence.write(_accountStores, () {
        for (final entry in snap.collections.entries) {
          if (entry.value.isNotEmpty) _apply(entry.key, entry.value);
        }
      });
    } finally {
      _applyingRemote = false;
    }
  }

  Future<bool> _recoverMissingCollections(AccountSnapshot snapshot) async {
    final missing = {
      for (final entry in snapshot.collections.entries)
        if (entry.value.isNotEmpty && _extract(entry.key).isEmpty)
          entry.key: entry.value,
    };
    if (missing.isEmpty) return false;
    _applyingRemote = true;
    try {
      AccountMutationFence.write(_accountStores, () {
        for (final entry in missing.entries) {
          _apply(entry.key, entry.value);
        }
      });
    } finally {
      _applyingRemote = false;
    }
    // Preserve offline drafts before publishing bookkeeping or allowing a
    // later sign-out to replace their recovery snapshot.
    await _persistCollections();
    return true;
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
    if (_mobileTrackingAvailable) await invalidateTrackingSampling();
    await LocationService.stopBackground();
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

  Future<void> _finishPendingRestoration() async {
    if (!meta.state.pendingRestoration) return;
    final email = meta.state.lastEmail;
    final snapshot = meta.state.accountSnapshots[email];
    if (snapshot == null) {
      throw StateError('Account recovery snapshot is missing');
    }
    // Retry even when ownership was already persisted in a prior process.
    // The original snapshot stays authoritative until every store is durable.
    await _persistMeta();
    _applySnapshot(snapshot);
    await _persistCollections();
    final bookkeeping = _restoredBookkeeping(snapshot);
    meta.reset(
      lastEmail: email,
      pendingRestoration: false,
      cursor: bookkeeping.cursor,
      items: bookkeeping.items,
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
    final email = auth.state.email.trim().toLowerCase();
    _blockAccountMutations();
    accountTransitioning.value = true;
    // Invalidate authentication before the first storage await. A new login
    // can wait for removal without being cancelled by a later logout.
    auth.logout();
    final transition = _signOut(clearLocalData, email);
    _accountTransition = transition;
    try {
      await transition;
    } finally {
      _unblockAccountMutations();
      _accountTransition = null;
      accountTransitioning.value = false;
    }
  }

  Future<void> _signOut(bool clearLocalData, String email) async {
    // A login/boot recovery already writing stores must settle before removal.
    await _accountPreparation;
    // Never replace the recovery copy with a partially restored live store.
    await _finishPendingRestoration();
    if (meta.state.pendingRemoval) {
      // Never replace the original snapshot with partially cleared data.
      await _finishPendingRemoval();
    } else {
      final owner = email.isEmpty ? meta.state.lastEmail ?? '' : email;
      await _capturePendingTracking(owner);
      meta.reset(
        lastEmail: owner,
        pendingRemoval: clearLocalData,
        accountSnapshots: owner.isEmpty
            ? meta.state.accountSnapshots
            : _withSnapshotFor(owner),
      );
      await _persistMeta();
      if (clearLocalData) await _finishPendingRemoval();
    }
    AccountMutationFence.write(_accountStores, plaid.clearLocalSession);
  }

  Future<void> _prepareAccount(String email) async {
    final previous = _accountPreparation;
    final preparation = () async {
      await previous;
      await _prepareAccountFenced(email);
    }();
    _accountPreparation = preparation;
    try {
      await preparation;
    } finally {
      if (identical(_accountPreparation, preparation)) {
        _accountPreparation = null;
      }
    }
  }

  Future<void> _prepareAccountFenced(String email) async {
    final owner = (meta.state.lastEmail ?? auth.state.email).trim().toLowerCase();
    final fenced =
        meta.state.pendingRemoval ||
        meta.state.pendingRestoration ||
        owner != email ||
        _accountStores.any((store) => store.accountMutationsBlocked);
    if (fenced) {
      _blockAccountMutations();
      accountTransitioning.value = true;
    }
    try {
      await _prepareAccountData(email);
    } finally {
      if (fenced && _accountTransition == null) {
        _unblockAccountMutations();
        accountTransitioning.value = false;
      }
    }
  }

  Future<void> _prepareAccountData(String email) async {
    await _finishPendingRestoration();
    await _finishPendingRemoval();
    final previous = meta.state.lastEmail?.trim().toLowerCase();
    if (previous != null &&
        previous.isNotEmpty &&
        email.isNotEmpty &&
        previous != email) {
      await _capturePendingTracking(previous);
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
    if (!_trackingQueueBound || tracking.pendingPointsAccount != email) {
      if (_mobileTrackingAvailable) await claimLegacyPendingPoints(email);
      tracking.pendingPointsAccount = email;
      _trackingQueueBound = true;
    }
    final restored = meta.state.accountSnapshots[email];
    final wiped = (meta.state.lastEmail ?? '').trim().toLowerCase() != email;
    final hasBaseline =
        restored != null &&
        (restored.cursor != null || restored.items.isNotEmpty);
    if (meta.state.cursor == null &&
        meta.state.items.isEmpty &&
        (hasBaseline || (wiped && restored != null))) {
      if (wiped) {
        // Claim ownership and recovery intent together before restoring any
        // collection. A crash cannot make ownership imply completion.
        meta.reset(
          lastEmail: email,
          pendingRestoration: true,
          accountSnapshots: meta.state.accountSnapshots,
        );
        await _finishPendingRestoration();
        return;
      }
      // A lost collection needs both the saved offline contents and a full
      // cloud pull. Recovered items keep their saved baseline so an unchanged
      // cloud copy cannot overwrite offline edits. Reset the cursor separately.
      // Never-synced Keep sessions
      // skip this branch: failed pulls must not resurrect deliberate deletes.
      final recovered = await _recoverMissingCollections(restored);
      final bookkeeping = _restoredBookkeeping(restored);
      meta.reset(
        lastEmail: email,
        cursor: recovered ? null : bookkeeping.cursor,
        items: bookkeeping.items,
        accountSnapshots: meta.state.accountSnapshots,
      );
      await _persistMeta();
    } else if (previous != email) {
      meta.save(lastEmail: email);
      await _persistMeta();
    }
  }

  /// Include queued mobile points in the outgoing account's durable snapshot.
  /// The account-scoped files also retain points from an interrupted drain.
  Future<void> _capturePendingTracking(String owner) async {
    if (!_mobileTrackingAvailable) return;
    await invalidateTrackingSampling();
    await LocationService.stopBackground();
    if (owner.isEmpty) return;
    await claimLegacyPendingPoints(owner);
    tracking.pendingPointsAccount = owner;
    final pending = await readPendingPoints(account: owner);
    AccountMutationFence.write(_accountStores, () {
      tracking.mergePoints(pending);
    });
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
