import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

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

/// Persisted sync cursor + per-item meta. Deliberately NOT synced itself
/// (each device tracks its own sync position).
class SyncMetaState extends Equatable {
  /// Last server_time from pull; null = never synced.
  final String? cursor;

  /// '$collection/$itemId' -> meta.
  final Map<String, ItemMeta> items;

  const SyncMetaState({this.cursor, this.items = const {}});

  SyncMetaState copyWith({String? cursor, Map<String, ItemMeta>? items}) =>
      SyncMetaState(cursor: cursor ?? this.cursor, items: items ?? this.items);

  @override
  List<Object?> get props => [cursor, items];
}

class SyncMetaCubit extends HydratedCubit<SyncMetaState> {
  SyncMetaCubit() : super(const SyncMetaState());

  static String key(String collection, String itemId) => '$collection/$itemId';

  void save({
    String? cursor,
    Map<String, ItemMeta>? upsert,
    Set<String>? remove,
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
    ));
  }

  /// Clears sync position (sign-out / account switch). Local data stays;
  /// the next sync re-baselines without pushing tombstones for everything.
  void reset() => emit(const SyncMetaState());

  @override
  SyncMetaState? fromJson(Map<String, dynamic> json) {
    try {
      final raw = (json['items'] as Map?) ?? const {};
      final items = <String, ItemMeta>{};
      for (final e in raw.entries) {
        try {
          final m = Map<String, dynamic>.from(e.value as Map);
          items[e.key.toString()] = ItemMeta(
            hash: m['hash'] as String? ?? '',
            serverTime: m['serverTime'] as String? ?? '',
          );
        } catch (_) {}
      }
      return SyncMetaState(
        cursor: json['cursor'] as String?,
        items: items,
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
      };
}
