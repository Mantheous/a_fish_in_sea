import '../sync/sync_client.dart';

/// One staged row inside an import batch. [existing] is the live sync row
/// with the same collection+item_id, when there is one — the review UI
/// renders it as "updates existing" instead of a silent overwrite.
class StagedItem {
  final String collection;
  final String itemId;
  final Map<String, dynamic> data;
  final String status; // 'pending' | 'approved' | 'rejected'
  final Map<String, dynamic>? existing;

  /// True when [existing] is a tombstone the user deleted in the app:
  /// approving restores it. Rendered explicitly, never silently.
  final bool existingDeleted;

  const StagedItem({
    required this.collection,
    required this.itemId,
    required this.data,
    this.status = 'pending',
    this.existing,
    this.existingDeleted = false,
  });

  bool get isNode => collection == 'nodes';
  bool get isPending => status == 'pending';
  bool get isUpdate => existing != null;

  String get title {
    final raw = isNode ? data['title'] : data['subject'];
    if (raw is String && raw.isNotEmpty) return raw;
    final fb = isNode ? data['subject'] : data['title'];
    return fb is String ? fb : '(untitled)';
  }

  /// Human date/time line for the preview row, or '' when dateless.
  String get when {
    if (isNode) {
      final sched = data['schedule'];
      final due = sched is Map ? sched['due'] : null;
      return due is String ? due : '';
    }
    final start = data['start'];
    return start is String ? start : '';
  }

  factory StagedItem.fromJson(Map<String, dynamic> json) => StagedItem(
        collection: json['collection'] as String? ?? '',
        itemId: json['item_id'] as String? ?? '',
        data: json['data'] is Map
            ? Map<String, dynamic>.from(json['data'] as Map)
            : const {},
        status: json['status'] as String? ?? 'pending',
        existing: json['existing'] is Map
            ? Map<String, dynamic>.from(json['existing'] as Map)
            : null,
        existingDeleted: json['existing_deleted'] as bool? ?? false,
      );
}

/// A third-party import batch awaiting (partial) approval.
class ImportBatch {
  final int id;
  final String source;
  final String status; // 'pending' | 'approved' | 'rejected'
  final DateTime? createdAt;
  final List<StagedItem> items;

  const ImportBatch({
    required this.id,
    required this.source,
    required this.status,
    required this.createdAt,
    required this.items,
  });

  List<StagedItem> get pending => items.where((i) => i.isPending).toList();
  int get pendingCount => pending.length;

  factory ImportBatch.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return ImportBatch(
      id: (json['id'] as num?)?.toInt() ?? 0,
      source: json['source'] as String? ?? 'import',
      status: json['status'] as String? ?? 'pending',
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      items: rawItems is List
          ? rawItems
              .whereType<Map>()
              .map((e) => StagedItem.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
    );
  }
}

/// Typed client for /api/v1/imports. Review calls are app-user only; the
/// server answers 403 for API tokens (they can submit, never self-approve).
class ImportService {
  final SyncClient client;

  ImportService(this.client);

  static const _base = '/api/v1/imports';

  /// The list endpoint answers `[]` when signed in; a captive portal or
  /// proxy can return HTML instead, so treat anything that isn't a list as
  /// empty — never throw.
  Future<List<ImportBatch>> pending() async {
    final body = await client.apiGet('$_base/pending');
    return _batches(body);
  }

  static List<ImportBatch> _batches(dynamic body) =>
      (body is List ? body : const <dynamic>[])
          .whereType<Map>()
          .map((e) => ImportBatch.fromJson(Map<String, dynamic>.from(e)))
          .toList();

  /// Approve the whole batch ([itemIds] null) or a subset. Returns the
  /// updated batch; resolved batches come back as approved/rejected.
  Future<ImportBatch> approve(int id, {List<String>? itemIds}) async {
    final body = await client.apiPost(
      '$_base/$id/approve',
      itemIds == null ? {} : {'item_ids': itemIds},
    );
    return ImportBatch.fromJson(
        Map<String, dynamic>.from((body ?? const <String, dynamic>{})));
  }

  /// Drop staged items without applying them. App data is never touched.
  Future<ImportBatch> discard(int id, List<String> itemIds) async {
    final body = await client.apiPost(
      '$_base/$id/discard',
      {'item_ids': itemIds},
    );
    return ImportBatch.fromJson(
        Map<String, dynamic>.from((body ?? const <String, dynamic>{})));
  }

  Future<ImportBatch> reject(int id) async {
    final body = await client.apiPost('$_base/$id/reject', {});
    return ImportBatch.fromJson(
        Map<String, dynamic>.from((body ?? const <String, dynamic>{})));
  }
}
