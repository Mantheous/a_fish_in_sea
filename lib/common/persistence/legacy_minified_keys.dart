import 'dart:convert';

import 'package:hive/hive.dart';

import 'stable_storage_keys.dart';

/// One-time recovery for prefs written under dart2js minified class names.
///
/// Before [StableStorageKeys], hydrated_bloc stored every cubit under
/// `runtimeType.toString()`. A release web build stores
/// `minified:<compiler name>` there, and those names shift between builds, so
/// a deploy left the real payload behind under the previous build's key and
/// booted from a fresh one. This scans the box for payloads whose shape
/// unambiguously identifies a *local-only* state and copies the best one onto
/// the stable key when that key has nothing yet.
///
/// Deliberately narrow: only device-local preferences and the auth session
/// are recovered. Synced collections (nodes, events, feeds, transactions,
/// settings, waterfall, plaid, places, reporting, tracked points) are left to
/// the sync engine's normal pull — copying a stale payload of one collection
/// while its sync bookkeeping starts empty could look like a mass deletion.
///
/// Never deletes anything and never overwrites an existing stable key, so
/// repeated boots are harmless.
Future<List<String>> migrateLegacyHydratedKeys(Box<dynamic> box) async {
  final best = <String, _Candidate>{};
  for (final key in box.keys) {
    if (key is! String || StableStorageKeys.all.contains(key)) continue;
    final value = box.get(key);
    final match = _classify(value);
    if (match == null) continue;
    final candidate = _Candidate(key, match);
    final previous = best[match.stableKey];
    if (previous == null || candidate.betterThan(previous)) {
      best[match.stableKey] = candidate;
    }
  }

  final migrated = <String>[];
  for (final entry in best.entries) {
    if (box.containsKey(entry.key)) continue;
    final payload = box.get(entry.value.sourceKey);
    if (payload == null) continue;
    await box.put(entry.key, payload);
    migrated.add(entry.key);
  }
  return migrated;
}

class _Candidate {
  final String sourceKey;
  final _Match match;

  const _Candidate(this.sourceKey, this.match);

  /// Newest payload wins; ties go to the richer state so payloads without
  /// timestamped ids still recover the user's rules instead of defaults.
  bool betterThan(_Candidate other) {
    if (match.recency != other.match.recency) {
      return match.recency > other.match.recency;
    }
    if (match.weight != other.match.weight) {
      return match.weight > other.match.weight;
    }
    return sourceKey.compareTo(other.sourceKey) > 0;
  }
}

class _Match {
  final String stableKey;
  final int recency;
  final int weight;

  const _Match(this.stableKey, {this.recency = 0, this.weight = 0});
}

_Match? _classify(Object? raw) {
  if (raw is! Map) return null;

  if (_looksLikeSignedInAuth(raw)) {
    return _Match(StableStorageKeys.auth, recency: _authRecency(raw));
  }
  if (_looksLikeTaskViewOptions(raw)) {
    return _Match(
      StableStorageKeys.tasksViewOptions,
      recency: _taskViewRecency(raw),
      weight: _taskViewWeight(raw),
    );
  }
  if (raw['hiddenIds'] is List) {
    return _Match(
      StableStorageKeys.calendarVisibility,
      weight: (raw['hiddenIds'] as List).length,
    );
  }
  if (raw['lastUsed'] is String) {
    return const _Match(StableStorageKeys.schedulePrefs);
  }
  if (_looksLikeAssignmentRules(raw)) {
    return _Match(
      StableStorageKeys.assignmentRules,
      recency: _assignmentRulesRecency(raw),
      weight: _list(raw['rules']).length,
    );
  }
  return null;
}

/// Signed-out payloads carry null tokens; restoring one over a real session
/// would force a needless re-login, so only payloads with a token match.
bool _looksLikeSignedInAuth(Map raw) {
  if (raw['status'] is! String) return false;
  final refresh = raw['refreshToken'];
  final access = raw['accessToken'];
  return (refresh is String && refresh.isNotEmpty) ||
      (access is String && access.isNotEmpty);
}

/// JWT `exp` (seconds) is the best recency signal for a session payload; the
/// newest token pair is the one the current device is still using. Opaque
/// tokens fall back to 1 so any signed-in payload beats none.
int _authRecency(Map raw) {
  final access = _jwtExpiry(raw['accessToken']);
  if (access > 0) return access;
  return _jwtExpiry(raw['refreshToken']).clamp(0, 1);
}

int _jwtExpiry(Object? raw) {
  if (raw is! String) return 0;
  final parts = raw.split('.');
  if (parts.length < 2) return 0;
  try {
    final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final decoded = jsonDecode(payload);
    if (decoded is Map) {
      final exp = decoded['exp'];
      if (exp is num) return exp.toInt();
      final iat = decoded['iat'];
      if (iat is num) return iat.toInt();
    }
  } catch (_) {
    // Opaque or malformed token: no useful timestamp.
  }
  return 0;
}

bool _looksLikeTaskViewOptions(Map raw) {
  if (raw['filters'] is List ||
      raw['activeFilterId'] is String ||
      raw['highlight'] is Map ||
      raw['dueFilter'] is String ||
      raw['highlightDueThisWeek'] is bool) {
    return true;
  }
  // `rules` on its own is the AssignmentRules shape; a TaskViewOptions
  // payload also always carries `filters`.
  final rules = raw['rules'];
  if (rules is List && rules.isNotEmpty) {
    final first = rules.first;
    return first is Map &&
        (first['selector'] is Map || first['effect'] is String);
  }
  return false;
}

/// User-built view/rule ids end in `DateTime.now().microsecondsSinceEpoch`,
/// so the payload with the largest stamped id is the most recent one.
int _taskViewRecency(Map raw) {
  var best = 0;
  void consider(Object? id) {
    if (id is! String) return;
    final colon = id.lastIndexOf(':');
    if (colon < 0 || colon == id.length - 1) return;
    final stamp = int.tryParse(id.substring(colon + 1));
    if (stamp != null && stamp > best) best = stamp;
  }

  for (final filter in _list(raw['filters'])) {
    if (filter is Map) consider(filter['id']);
  }
  for (final rule in _list(raw['rules'])) {
    if (rule is Map) {
      consider(rule['id']);
      final selector = rule['selector'];
      if (selector is Map) consider(selector['id']);
    }
  }
  consider(raw['activeFilterId']);
  return best;
}

/// Fallback ordering when no custom ids exist: the payload that still keeps
/// the most rules/views is closer to what the user had than stock defaults.
int _taskViewWeight(Map raw) {
  final rules = _list(raw['rules']);
  final enabled = rules.where((r) => r is Map && r['enabled'] == true).length;
  return (_list(raw['filters']).length + rules.length) * 2 + enabled;
}

bool _looksLikeAssignmentRules(Map raw) {
  final rules = raw['rules'];
  if (rules is! List) return false;
  // An empty list alone is AssignmentRules: TaskViewOptions always writes
  // `filters` next to its rules.
  if (rules.isEmpty) return true;
  final first = rules.first;
  return first is Map &&
      (first['feedId'] is String || first['templateKey'] is String);
}

int _assignmentRulesRecency(Map raw) {
  var best = 0;
  for (final rule in _list(raw['rules'])) {
    if (rule is! Map) continue;
    final created = rule['createdAt'];
    if (created is! String) continue;
    final parsed = DateTime.tryParse(created);
    if (parsed != null && parsed.millisecondsSinceEpoch > best) {
      best = parsed.millisecondsSinceEpoch;
    }
  }
  return best;
}

List<dynamic> _list(Object? raw) => raw is List ? raw : const [];
