part of 'sync_engine.dart';

extension SyncCollections on SyncEngine {
  // ── Extract (cubit -> {itemId: data}) ────────────────────────────────

  Map<String, Map<String, dynamic>> _extract(String collection) {
    List<dynamic> listOf(Map<String, dynamic>? env, String key) {
      final l = env?[key];
      return l is List ? l : const [];
    }

    Map<String, dynamic> asMap(dynamic e) =>
        Map<String, dynamic>.from(e as Map);

    Map<String, Map<String, dynamic>> idMap(List<dynamic> list) => {
      for (final e in list)
        if (asMap(e)['id'] is String) (asMap(e)['id'] as String): asMap(e),
    };

    switch (collection) {
      case 'nodes':
        return idMap(listOf(nodes.toJson(nodes.state), 'nodes'));
      case 'events':
        return idMap(listOf(events.toJson(events.state), 'events'));
      case 'feeds':
        return idMap(listOf(feeds.toJson(feeds.state), 'feeds'));
      case 'transactions':
        return idMap(
          listOf(transactions.toJson(transactions.state), 'transactions'),
        );
      case 'places':
        return idMap(listOf(places.toJson(places.state), 'places'));
      case 'reported_entries':
        {
          final days = reporting.toJson(reporting.state)['days'];
          final out = <String, Map<String, dynamic>>{};
          if (days is Map) {
            for (final entry in days.entries) {
              final day = entry.key.toString();
              final items = entry.value is List
                  ? entry.value as List
                  : const [];
              out[day] = {
                'day': day,
                'entries': [
                  for (final e in items) Map<String, dynamic>.from(e as Map),
                ],
              };
            }
          }
          return out;
        }
      case 'tracked_points':
        {
          return idMap(listOf(tracking.toJson(tracking.state), 'points'));
        }
      case 'settings':
        {
          final env = Map<String, dynamic>.from(
            settings.toJson(settings.state),
          );
          SyncEngine._stripDeviceLocalFields('settings', env);
          return {'singleton': env};
        }
      case 'waterfall':
        {
          final env = waterfall.toJson(waterfall.state);
          return {
            'singleton': env == null
                ? <String, dynamic>{}
                : Map<String, dynamic>.from(env),
          };
        }
      case 'plaid':
        {
          final env = plaid.toJson(plaid.state);
          final map = env == null
              ? <String, dynamic>{}
              : Map<String, dynamic>.from(env);
          SyncEngine._stripDeviceLocalFields('plaid', map);
          return {'singleton': map};
        }
    }
    return {};
  }

  // ── Apply merged maps back into cubits (no undo records) ────────────

  void _apply(String collection, Map<String, Map<String, dynamic>> items) {
    switch (collection) {
      case 'nodes':
        nodes.applyJson({'nodes': items.values.toList()});
        break;
      case 'events':
        events.applyJson({'events': items.values.toList()});
        break;
      case 'feeds':
        feeds.applyJson({'feeds': items.values.toList()});
        break;
      case 'transactions':
        transactions.applySyncedJson({'transactions': items.values.toList()});
        break;
      case 'places':
        places.applyJson({'places': items.values.toList()});
        break;
      case 'reported_entries':
        reporting.applyJson({
          'days': {for (final e in items.entries) e.key: e.value['entries']},
        });
        break;
      case 'tracked_points':
        tracking.applySyncedPoints(items.values.toList());
        break;
      case 'settings':
        final data = items['singleton'];
        if (data != null) settings.applySyncedJson(data);
        break;
      case 'waterfall':
        final data = items['singleton'];
        if (data != null) waterfall.applySyncedConfig(data);
        break;
      case 'plaid':
        final data = items['singleton'];
        if (data != null) plaid.applySyncedIdentity(data);
        break;
    }
  }
}
