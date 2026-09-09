import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../model/task_assignee.dart';

class GoogleContact {
  final String id;
  final String displayName;
  final String? email;
  final String? photoUrl;

  const GoogleContact({
    required this.id,
    required this.displayName,
    this.email,
    this.photoUrl,
  });

  String get searchKey =>
      '${displayName.toLowerCase()} ${(email ?? '').toLowerCase()}';

  bool matchesQuery(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return searchKey.contains(q);
  }

  TaskAssignee toAssignee() => TaskAssignee(
        id: id,
        displayName: displayName,
        email: email,
        photoUrl: photoUrl,
      );

  factory GoogleContact.fromJson(Map<String, dynamic> json) {
    final rawId = (json['id'] as String?)?.trim() ?? '';
    final rawName = (json['displayName'] as String?)?.trim() ?? '';
    final rawEmail = (json['email'] as String?)?.trim();
    final rawPhoto = (json['photoUrl'] as String?)?.trim();
    final id = rawId.isNotEmpty
        ? rawId
        : (rawEmail ?? '').isNotEmpty
            ? rawEmail!
            : rawName;
    final displayName =
        rawName.isNotEmpty ? rawName : (rawEmail ?? '').isNotEmpty ? rawEmail! : id;
    if (id.isEmpty || displayName.isEmpty) {
      throw const FormatException('Contact needs an id or name');
    }
    return GoogleContact(
      id: id,
      displayName: displayName,
      email: (rawEmail ?? '').isEmpty ? null : rawEmail,
      photoUrl: (rawPhoto ?? '').isEmpty ? null : rawPhoto,
    );
  }
}

class GoogleContactsException implements Exception {
  final String message;
  final int? statusCode;
  final bool needsReconnect;
  const GoogleContactsException(
    this.message, {
    this.statusCode,
    this.needsReconnect = false,
  });

  @override
  String toString() => message;
}

class GoogleContactsStatus {
  final bool connected;
  final bool contactsGranted;
  const GoogleContactsStatus({
    required this.connected,
    required this.contactsGranted,
  });
}

/// Talks to the Python server's People proxy. The server holds the OAuth
/// tokens, so the app only deals with a cached flat contact list that the
/// task editor filters locally.
class GoogleContactsService {
  final String Function() baseUrl;
  final String Function() userId;
  final http.Client _client;
  List<GoogleContact>? _cache;

  GoogleContactsService({
    required this.baseUrl,
    required this.userId,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Map<String, String> get _headers => {'X-App-User-Id': userId()};

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = baseUrl().trim().replaceAll(RegExp(r'/+$'), '');
    final effectiveBase = base.isEmpty
        ? (kIsWeb ? Uri.base.origin : 'http://127.0.0.1:8000')
        : base;
    final resolved = Uri.parse(
      effectiveBase.isEmpty ? path : '$effectiveBase$path',
    );
    if (query == null) return resolved;
    return resolved.replace(queryParameters: {
      ...resolved.queryParameters,
      ...query,
    });
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.statusCode != 200) {
      String message = 'Server returned ${response.statusCode}';
      bool needsReconnect = false;
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['error'] is String) {
          message = body['error'] as String;
        }
        if (body is Map && body['needsReconnect'] == true) {
          needsReconnect = true;
        }
      } catch (_) {}
      if (response.statusCode == 401 || response.statusCode == 403) {
        needsReconnect = true;
      }
      throw GoogleContactsException(
        message,
        statusCode: response.statusCode,
        needsReconnect: needsReconnect,
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<GoogleContactsStatus> status() async {
    final data = _decode(await _client.get(_uri('/api/google/status'),
        headers: _headers));
    return GoogleContactsStatus(
      connected: data['connected'] as bool? ?? false,
      contactsGranted: data['contactsGranted'] as bool? ?? false,
    );
  }

  Future<List<GoogleContact>> fetchContacts({bool forceRefresh = false}) async {
    if (!forceRefresh && _cache != null) return _cache!;
    final data = _decode(await _client.get(_uri('/api/google/contacts'),
        headers: _headers));
    final list = data['contacts'];
    final out = <GoogleContact>[];
    if (list is List) {
      for (final raw in list) {
        if (raw is! Map<String, dynamic>) continue;
        try {
          out.add(GoogleContact.fromJson(raw));
        } catch (_) {}
      }
    }
    out.sort((a, b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    _cache = out;
    return out;
  }

  List<GoogleContact> searchCached(String query, {int limit = 20}) {
    final cache = _cache;
    if (cache == null) return const [];
    final q = query.trim().toLowerCase();
    final matches = q.isEmpty
        ? cache.take(limit).toList()
        : cache.where((c) => c.matchesQuery(q)).take(limit).toList();
    return matches;
  }

  void clearCache() => _cache = null;
}
