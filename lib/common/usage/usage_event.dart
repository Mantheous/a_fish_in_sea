import 'dart:convert';

/// One content-free usage event.
///
/// The log deliberately records only *what happened*, never what the user
/// typed or what the data was: [name] comes from a closed set of strings,
/// [meta] holds primitives (enum names, booleans, counts), and free text is
/// never accepted. [screen] is a navigation page name, not a title.
///
/// Wire shape is intentionally small (the client may queue ~2k events):
/// `{id, at, kind, name, screen, duration_ms, meta}`.
class UsageEvent {
  /// Allowed event kinds. Keep in sync with the server's Literal and the
  /// digest script; an unknown kind is dropped on read/ingest.
  static const Set<String> kinds = {
    'app',
    'screen',
    'action',
    'error',
    'slow',
    'sync',
  };

  static final RegExp _namePattern = RegExp(r'^[a-z0-9][a-z0-9_.:-]{0,63}$');
  static final RegExp _keyPattern = RegExp(r'^[a-z][a-z0-9_]{0,23}$');

  final String id;
  final int atMs;
  final String kind;
  final String name;
  final String screen;
  final int? durationMs;
  final Map<String, Object?> meta;

  const UsageEvent({
    required this.id,
    required this.atMs,
    required this.kind,
    required this.name,
    this.screen = '',
    this.durationMs,
    this.meta = const {},
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'at': atMs,
    'kind': kind,
    'name': name,
    if (screen.isNotEmpty) 'screen': screen,
    if (durationMs != null) 'duration_ms': durationMs,
    if (meta.isNotEmpty) 'meta': meta,
  };

  /// Tolerant reader: a malformed row must never take the log down or
  /// abort a batch. Returns null instead of throwing.
  static UsageEvent? tryFromJson(Object? raw) {
    try {
      final map = raw is String
          ? Map<String, dynamic>.from(jsonDecode(raw) as Map)
          : raw is Map
          ? Map<String, dynamic>.from(raw)
          : null;
      if (map == null) return null;
      final id = map['id'];
      final at = map['at'];
      final kind = map['kind'];
      final name = map['name'];
      final screen = map['screen'];
      final duration = map['duration_ms'];
      if (id is! String || id.length < 8 || id.length > 64) return null;
      if (at is! num) return null;
      if (kind is! String || !kinds.contains(kind)) return null;
      if (name is! String || !_namePattern.hasMatch(name)) return null;
      final screenName = screen is String && _namePattern.hasMatch(screen)
          ? screen
          : '';
      final durationMs = duration is num && duration >= 0
          ? duration.toInt()
          : null;
      final rawMeta = map['meta'];
      final meta = <String, Object?>{};
      if (rawMeta is Map) {
        for (final entry in rawMeta.entries) {
          final key = entry.key;
          final value = entry.value;
          if (key is! String || !_keyPattern.hasMatch(key)) continue;
          if (value is bool || value is int || value is double) {
            meta[key] = value;
          } else if (value is String &&
              RegExp(r'^[a-z0-9][a-z0-9_.:-]{0,39}$').hasMatch(value)) {
            meta[key] = value;
          }
        }
      }
      return UsageEvent(
        id: id,
        atMs: at.toInt(),
        kind: kind,
        name: name,
        screen: screenName,
        durationMs: durationMs,
        meta: meta,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Maps a page/view/action name to the closed vocabulary.
///
/// This is the one place that decides what a usage string may look like.
/// It is deliberately lossy: a title like "Quiz 4" becomes "invalid" and
/// never leaves the device.
String usageName(Object? raw) {
  final value = (raw ?? '').toString().toLowerCase();
  // Content-free by construction: a title/notes string contains spaces or
  // punctuation outside this alphabet and is collapsed to `invalid` instead
  // of being smuggled into the log.
  if (!RegExp(r'^[a-z0-9][a-z0-9_.:-]{0,63}$').hasMatch(value)) {
    return 'invalid';
  }
  return value;
}

/// Sanitizes a metadata value. Only short closed-set tokens, numbers, and
/// booleans survive; free text (spaces, unicode, long strings) is dropped.
Object? usageMetaValue(Object? value) {
  if (value is bool || value is int) return value;
  if (value is double) return value.isFinite ? value : null;
  if (value is Enum) return usageName(value.name);
  if (value is String) {
    final lower = value.toLowerCase();
    if (!RegExp(r'^[a-z0-9][a-z0-9_.:-]{0,39}$').hasMatch(lower)) return null;
    return lower;
  }
  return null;
}
