import 'package:equatable/equatable.dart';

/// A durable association with one calendar series. Reconciled records stay
/// here as complete JSON snapshots, including notes, reports and source ids.
/// This is additive: older nodes have no link and require no schema migration.
class NodeCalendarLink extends Equatable {
  final String seriesKey;
  final bool isEnabled;

  /// Explicitly detached occurrences must not reattach on the next import.
  final Set<String> excludedEventIds;
  final Map<String, Map<String, dynamic>> records;

  const NodeCalendarLink({
    required this.seriesKey,
    this.isEnabled = true,
    this.records = const {},
    this.excludedEventIds = const {},
  });

  static NodeCalendarLink? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['seriesKey'];
    if (key is! String || key.isEmpty) return null;
    final records = <String, Map<String, dynamic>>{};
    final stored = raw['records'];
    if (stored is Map) {
      for (final entry in stored.entries) {
        if (entry.key is! String || entry.value is! Map) continue;
        try {
          records[entry.key as String] = Map<String, dynamic>.from(
            entry.value as Map,
          );
        } catch (_) {
          // One malformed snapshot never drops the goal or other snapshots.
        }
      }
    }
    return NodeCalendarLink(
      seriesKey: key,
      isEnabled: raw['isEnabled'] != false,
      records: records,
      excludedEventIds: raw['excludedEventIds'] is List
          ? (raw['excludedEventIds'] as List).whereType<String>().toSet()
          : const {},
    );
  }

  Map<String, dynamic> toJson() => {
    'seriesKey': seriesKey,
    'isEnabled': isEnabled,
    'records': records,
    'excludedEventIds': excludedEventIds.toList(),
  };

  @override
  List<Object?> get props => [seriesKey, isEnabled, records, excludedEventIds];
}
