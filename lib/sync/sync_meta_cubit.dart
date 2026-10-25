import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

import '../common/persistence/stable_storage_keys.dart';

/// Stable FNV-1a 32-bit hash over canonical JSON. Used only for
/// change-detection against this device's own last-synced snapshot
/// (hashes are never compared across devices), so insertion-ordered
/// jsonEncode from the same toJson code is deterministic enough.
/// 32-bit (not 64) so the literals compile to JavaScript exactly.
String contentHash(Map<String, dynamic> item) {
  const fnvPrime = 0x01000193;
  var hash = 0x811c9dc5;
  final bytes = utf8.encode(jsonEncode(item));
  for (final b in bytes) {
    hash ^= b;
    hash = (hash * fnvPrime) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16);
}

/// Per-item sync bookkeeping: what we last pushed/pulled.
class ItemMeta extends Equatable {
  /// Hash of the item content at last sync (our own hash space).
  final String hash;

  /// Server updated_at (ISO string) we last saw for this item.
  final String serverTime;

  const ItemMeta({required this.hash, required this.serverTime});

  @override
  List<Object?> get props => [hash, serverTime];
}

/// Per-account saved state (sync cursor, item meta, and local collection data)
/// so switching accounts on a shared device preserves each account's exact
/// sync baseline and unsynced local edits across app restarts.
class AccountSnapshot extends Equatable {
  final String? cursor;
  final Map<String, ItemMeta> items;
  final Map<String, Map<String, Map<String, dynamic>>> collections;

  const AccountSnapshot({
    this.cursor,
    this.items = const {},
    this.collections = const {},
  });

  AccountSnapshot copyWith({
    String? cursor,
    bool clearCursor = false,
    Map<String, ItemMeta>? items,
    Map<String, Map<String, Map<String, dynamic>>>? collections,
  }) =>
      AccountSnapshot(
        cursor: clearCursor ? null : (cursor ?? this.cursor),
        items: items ?? this.items,
        collections: collections ?? this.collections,
      );

  Map<String, dynamic> toJson() => {
        if (cursor != null) 'cursor': cursor,
        'items': {
          for (final e in items.entries)
            e.key: {'hash': e.value.hash, 'serverTime': e.value.serverTime},
        },
        'collections': collections,
      };

  static AccountSnapshot? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final rawCursor = raw['cursor'];
    final cursor =
        rawCursor is String && rawCursor.isNotEmpty ? rawCursor : null;
    final items = <String, ItemMeta>{};
    final rawItems = raw['items'];
    if (rawItems is Map) {
      for (final e in rawItems.entries) {
        try {
          if (e.value is! Map) continue;
          final m = Map<String, dynamic>.from(e.value as Map);
          final h = m['hash'];
          final t = m['serverTime'];
          if (h is String && t is String) {
            items[e.key.toString()] = ItemMeta(hash: h, serverTime: t);
          }
        } catch (_) {}
      }
    }
    final collections = <String, Map<String, Map<String, dynamic>>>{};
    final rawColls = raw['collections'];
    if (rawColls is Map) {
      for (final coll in rawColls.entries) {
        if (coll.value is! Map) continue;
        final itemMap = <String, Map<String, dynamic>>{};
        for (final item in (coll.value as Map).entries) {
          if (item.value is Map) {
            itemMap[item.key.toString()] =
                Map<String, dynamic>.from(item.value as Map);
          }
        }
        collections[coll.key.toString()] = itemMap;
      }
    } else {
      // Legacy shape where the map directly held {collection -> {itemId -> data}}.
      for (final coll in raw.entries) {
        if (coll.key == 'cursor' || coll.key == 'items') continue;
        if (coll.value is! Map) continue;
        final itemMap = <String, Map<String, dynamic>>{};
        for (final item in (coll.value as Map).entries) {
          if (item.value is Map) {
            itemMap[item.key.toString()] =
                Map<String, dynamic>.from(item.value as Map);
          }
        }
        collections[coll.key.toString()] = itemMap;
      }
    }
    return AccountSnapshot(
      cursor: cursor,
      items: items,
      collections: collections,
    );
  }

  @override
  List<Object?> get props => [cursor, items, collections];
}

/// Persisted sync cursor + per-item meta. Deliberately NOT synced itself
/// (each device tracks its own sync position).
class SyncMetaState extends Equatable {
  /// Last server_time from pull; null = never synced.
  final String? cursor;

  /// '$collection/$itemId' -> meta.
  final Map<String, ItemMeta> items;

  /// Normalized email of the account whose data currently lives on this
  /// device. Additive nullable field so old payloads load unchanged.
  final String? lastEmail;

  /// Persisted per-account snapshots of sync meta + local collections so
  /// switching accounts on a shared device never loses unsynced local edits
  /// across app restarts AND never leaks one account's data into another.
  final Map<String, AccountSnapshot> accountSnapshots;

  const SyncMetaState({
    this.cursor,
    this.items = const {},
    this.lastEmail,
    this.accountSnapshots = const {},
  });

  SyncMetaState copyWith({
    String? cursor,
    Map<String, ItemMeta>? items,
    String? lastEmail,
    Map<String, AccountSnapshot>? accountSnapshots,
  }) =>
      SyncMetaState(
        cursor: cursor ?? this.cursor,
        items: items ?? this.items,
        lastEmail: lastEmail ?? this.lastEmail,
        accountSnapshots: accountSnapshots ?? this.accountSnapshots,
      );

  @override
  List<Object?> get props => [cursor, items, lastEmail, accountSnapshots];
}

class SyncMetaCubit extends HydratedCubit<SyncMetaState> {
  SyncMetaCubit() : super(const SyncMetaState());

  @override
  String get storagePrefix => StableStorageKeys.syncMeta;

  static String key(String collection, String itemId) => '$collection/$itemId';

  void save({
    String? cursor,
    Map<String, ItemMeta>? upsert,
    Set<String>? remove,
    String? lastEmail,
    Map<String, AccountSnapshot>? accountSnapshots,
  }) {
    final next = Map<String, ItemMeta>.of(state.items);
    if (upsert != null) next.addAll(upsert);
    if (remove != null) {
      for (final k in remove) {
        next.remove(k);
      }
    }
    emit(state.copyWith(
      cursor: cursor ?? state.cursor,
      items: next,
      lastEmail: lastEmail ?? state.lastEmail,
      accountSnapshots: accountSnapshots ?? state.accountSnapshots,
    ));
  }

  /// Clears active sync position (sign-out / account switch). Preserves the
  /// outgoing account's cursor + item meta inside [accountSnapshots] under
  /// [lastEmail] so returning to that account reseeds its sync bookkeeping
  /// instead of overwriting unsynced local edits on pull.
  void reset({
    bool clearLastEmail = false,
    String? lastEmail,
    String? cursor,
    Map<String, ItemMeta>? items,
    Map<String, AccountSnapshot>? accountSnapshots,
  }) {
    final effectiveLast =
        lastEmail ?? (clearLastEmail ? null : state.lastEmail);
    final snaps = Map<String, AccountSnapshot>.of(
      accountSnapshots ?? state.accountSnapshots,
    );
    final prevKey = (state.lastEmail ?? '').trim().toLowerCase();
    if (accountSnapshots == null &&
        prevKey.isNotEmpty &&
        (state.cursor != null || state.items.isNotEmpty)) {
      final existing = snaps[prevKey] ?? const AccountSnapshot();
      snaps[prevKey] = existing.copyWith(
        cursor: state.cursor,
        items: Map<String, ItemMeta>.of(state.items),
      );
    }
    emit(SyncMetaState(
      cursor: cursor,
      items: items ?? const {},
      lastEmail: effectiveLast,
      accountSnapshots: snaps,
    ));
  }

  @override
  SyncMetaState? fromJson(Map<String, dynamic> json) {
    try {
      final raw = (json['items'] as Map?) ?? const {};
      final items = <String, ItemMeta>{};
      for (final e in raw.entries) {
        try {
          if (e.value is! Map) continue;
          final m = Map<String, dynamic>.from(e.value as Map);
          final h = m['hash'];
          final t = m['serverTime'];
          if (h is! String || t is! String) continue;
          items[e.key.toString()] = ItemMeta(hash: h, serverTime: t);
        } catch (_) {}
      }
      final rawSnaps = json['accountSnapshots'];
      final snaps = <String, AccountSnapshot>{};
      if (rawSnaps is Map) {
        for (final acct in rawSnaps.entries) {
          final parsed = AccountSnapshot.fromJson(acct.value);
          if (parsed != null) {
            snaps[acct.key.toString()] = parsed;
          }
        }
      }
      final rawEmail = json['lastEmail'];
      return SyncMetaState(
        cursor: json['cursor'] as String?,
        items: items,
        lastEmail: rawEmail is String && rawEmail.isNotEmpty ? rawEmail : null,
        accountSnapshots: snaps,
      );
    } catch (_) {
      return const SyncMetaState();
    }
  }

  @override
  Map<String, dynamic> toJson(SyncMetaState state) => {
        'cursor': state.cursor,
        'items': {
          for (final e in state.items.entries)
            e.key: {'hash': e.value.hash, 'serverTime': e.value.serverTime},
        },
        if (state.lastEmail != null) 'lastEmail': state.lastEmail,
        if (state.accountSnapshots.isNotEmpty)
          'accountSnapshots': {
            for (final e in state.accountSnapshots.entries)
              e.key: e.value.toJson(),
          },
      };
}
